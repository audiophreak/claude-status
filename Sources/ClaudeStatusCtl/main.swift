import ClaudeStatusCore
import Darwin
import Foundation

// claude-status-ctl: installation, verification and diagnostics for Claude Status.
// All settings edits go through HookConfigurator (structured, verified, atomic, backed up).

let usage = """
usage: claude-status-ctl <command> [options]

commands:
  install-hooks      Register Claude Status hooks (idempotent)
  uninstall-hooks    Remove only Claude Status hooks
  verify-hooks       Exit 0 if hooks are correctly installed
  install-helpers    --from DIR: copy claude-status-hook/ctl from DIR to the stable bin directory
  verify-preserved   --backup FILE: confirm everything except Claude Status hooks matches FILE
  restore-backup     --backup FILE: restore FILE only if nothing else changed since it was taken
  diagnose           Print monitoring health, coverage and process correlation (--json)
  selftest           Run the hook executable against an isolated temporary store and check
                     ingestion and state derivation (foreground, background, completion)
  report             Sanitized diagnostic report for bug reports (Markdown; no session ids,
                     project names, paths or payload data). --include-names adds project names.
                     --output FILE writes it to a file (mode 0600) instead of stdout
  version            Print the Claude Status version
  list               List tracked and detected-but-unobserved sessions
  clear-finished     Remove finished sessions (hidden while their process still runs)
  purge-state        --yes: delete session records and logs (keeps settings backups unless --include-backups)

options:
  --settings PATH    Settings file (default ~/.claude/settings.json)
  --hook-path PATH   Hook executable path to register (default: installed location)
  --home PATH        Claude Status state root (default ~/Library/Application Support/ClaudeStatus)
  --dry-run          Show what would change without writing
"""

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { FileHandle.standardError.write(Data(usage.utf8)); exit(64) }
args.removeFirst()

func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func flag(_ name: String) -> Bool { args.contains(name) }
func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8)); exit(code)
}
func absURL(_ p: String) -> URL {
    let expanded = (p as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { fail("path must be absolute: \(p)", code: 64) }
    return URL(fileURLWithPath: expanded)
}

let paths: StatusPaths = option("--home").map { StatusPaths(root: absURL($0)) } ?? StatusPaths.fromEnvironment()
let settingsURL = option("--settings").map(absURL) ?? ClaudePaths.userSettings()
let hookPath = option("--hook-path").map { absURL($0).path } ?? paths.hookExecutable.path
let configurator = HookConfigurator(settingsURL: settingsURL, hookCommandPath: hookPath, backupsDir: paths.backupsDir)
let now = Date().timeIntervalSince1970

func describe(_ s: HookInstallStatus) -> String {
    var out = "hooks: \(s.kind.rawValue)"
    if !s.missingEvents.isEmpty && s.kind != .notInstalled { out += " (missing: \(s.missingEvents.joined(separator: ", ")))" }
    if !s.duplicateEvents.isEmpty { out += " (duplicates: \(s.duplicateEvents.joined(separator: ", ")))" }
    if s.mismatchedCommand { out += " (command mismatch)" }
    if let d = s.detail { out += " [\(d)]" }
    return out
}

func writeManifest(_ backup: String?) {
    let data = (try? Data(contentsOf: configurator.settingsURL.resolvingSymlinksInPath())) ?? Data()
    let manifest: [String: Any] = [
        "version": ClaudeStatusVersion.current,
        "installedAt": ISO8601DateFormatter().string(from: Date()),
        "settingsPath": configurator.settingsURL.path,
        "hookCommand": configurator.hookCommand,
        "events": configurator.events,
        "settingsSHA256AfterInstall": HookConfigurator.sha256(data),
        "backup": backup ?? NSNull(),
    ]
    if let json = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
        try? paths.ensureDirectories()
        try? SessionStore.atomicWrite(json, to: paths.installManifest, mode: 0o600)
    }
}

func loadJSON(_ url: URL) -> JSONValue {
    guard let d = try? Data(contentsOf: url) else { fail("cannot read \(url.path)") }
    do { return try OrderedJSONParser.parse(d) } catch { fail("\(url.lastPathComponent) is not valid JSON: \(error)") }
}

switch command {
case "install-hooks":
    var lastError: Error?
    for attempt in 1...3 {
        do {
            let r = try configurator.install(dryRun: flag("--dry-run"))
            if !r.changed {
                print("Claude Status hooks already installed in \(settingsURL.path); no change.")
            } else {
                print("\(flag("--dry-run") ? "Would update" : "Updated") \(settingsURL.path)")
                if !r.addedEvents.isEmpty { print("  added: \(r.addedEvents.joined(separator: ", "))") }
                if !r.updatedEvents.isEmpty { print("  repaired: \(r.updatedEvents.joined(separator: ", "))") }
                if r.removedDuplicates > 0 { print("  duplicate registrations removed: \(r.removedDuplicates)") }
                if let b = r.backupPath { print("  backup: \(b)") }
                if !flag("--dry-run") { writeManifest(r.backupPath) }
            }
            print(describe(configurator.status()))
            exit(0)
        } catch ConfigError.concurrentModification {
            lastError = ConfigError.concurrentModification
            FileHandle.standardError.write(Data("settings changed during update (attempt \(attempt)); retrying\n".utf8))
            usleep(300_000)
        } catch {
            fail("\(error)")
        }
    }
    fail("\(lastError.map { "\($0)" } ?? "unknown error")")

case "uninstall-hooks":
    for attempt in 1...3 {
        do {
            let r = try configurator.uninstall(dryRun: flag("--dry-run"))
            if !r.changed { print("No Claude Status hooks found in \(settingsURL.path); no change.") }
            else {
                print("\(flag("--dry-run") ? "Would remove" : "Removed") \(r.removedHooks) Claude Status hook handler(s) from: \(r.removedEvents.joined(separator: ", "))")
                if let b = r.backupPath { print("  backup: \(b)") }
            }
            exit(0)
        } catch ConfigError.concurrentModification {
            FileHandle.standardError.write(Data("settings changed during update (attempt \(attempt)); retrying\n".utf8))
            usleep(300_000)
        } catch {
            fail("\(error)")
        }
    }
    fail("settings kept changing; nothing was written")

case "install-helpers":
    guard let from = option("--from") else { fail("--from DIR required", code: 64) }
    do {
        switch try HelperInstaller.install(from: absURL(from), paths: paths) {
        case .upToDate: print("Helpers already up to date in \(paths.binDir.path)")
        case .installed(let names): print("Installed \(names.joined(separator: ", ")) to \(paths.binDir.path)")
        }
    } catch { fail("\(error)") }

case "verify-hooks":
    let s = configurator.status()
    print(describe(s))
    exit(s.isHealthy ? 0 : 1)

case "verify-preserved":
    guard let b = option("--backup") else { fail("--backup FILE required", code: 64) }
    let backup = HookConfigurator.normalized(loadJSON(absURL(b)))
    let current = HookConfigurator.normalized(loadJSON(settingsURL.resolvingSymlinksInPath()))
    if backup == current {
        print("PRESERVED: apart from Claude Status hooks, \(settingsURL.path) is identical to the backup.")
        exit(0)
    }
    print("DIFFERENT: settings other than Claude Status hooks differ from the backup (changes made since it was taken).")
    exit(1)

case "restore-backup":
    guard let b = option("--backup") else { fail("--backup FILE required", code: 64) }
    let backupURL = absURL(b)
    let backupValue = loadJSON(backupURL)
    let current = loadJSON(settingsURL.resolvingSymlinksInPath())
    guard HookConfigurator.normalized(backupValue) == HookConfigurator.normalized(current) else {
        fail("refusing to restore: the settings file has other changes since this backup. Use uninstall-hooks instead.")
    }
    // Equivalent content apart from our hooks: restoring is a selective operation in effect.
    let r = try? configurator.uninstall()
    let after = loadJSON(settingsURL.resolvingSymlinksInPath())
    let ok = HookConfigurator.normalized(after) == HookConfigurator.normalized(backupValue)
    print(ok ? "Restored (Claude Status hooks removed; \(r?.removedHooks ?? 0) handler(s))." : "Restore verification failed")
    exit(ok ? 0 : 1)

case "diagnose":
    let store = SessionStore(paths: paths)
    let (records, corrupt) = store.loadAll()
    let procs = ProcessInspector.detectSessions(now: now)
    let h = MonitoringHealth.check(paths: paths, settingsURL: settingsURL, records: records, corrupt: corrupt.count, processes: procs)
    let appRunning = !NSRunningApplicationList.running().isEmpty
    let unobserved = Presentation.unobservedProcesses(procs, records: records)
    let liveRecords = records.filter { !$0.ended }
    func mapping(_ p: DetectedProcess) -> String {
        if let r = liveRecords.first(where: { $0.pid == p.pid }) { return String(r.sessionId.prefix(8)) }
        return unobserved.contains(p) ? "UNOBSERVED" : "matched-by-cwd"
    }
    if flag("--json") {
        let obj: [String: Any] = [
            "version": ClaudeStatusVersion.current,
            "level": h.level.rawValue,
            "hooks": h.hookStatus.kind.rawValue,
            "hookExecutablePresent": h.hookExecutablePresent,
            "hookLastRanAt": h.hookLastRanAt ?? NSNull(),
            "recentHookFailures": h.recentHookFailures,
            "storeAccessible": h.storeAccessible,
            "lastEventAt": h.lastEventAt ?? NSNull(),
            "sessions": records.count,
            "corruptRecords": corrupt.count,
            "runningClaudeProcesses": h.runningClaudeProcesses ?? NSNull(),
            "unobservedClaudeProcesses": h.unobservedClaudeProcesses,
            "coverageComplete": h.coverageComplete,
            "backgroundVisibility": h.backgroundVisibility.rawValue,
            "processes": procs.map { ["pid": Int($0.pid), "client": $0.client.rawValue, "session": mapping($0)] as [String: Any] },
            "appRunning": appRunning,
            "problems": h.problems,
        ]
        let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: d, as: UTF8.self))
    } else {
        print("Claude Status \(ClaudeStatusVersion.current) diagnostics")
        print("  health:            \(h.level.rawValue.uppercased()) — \(h.summary)")
        print("  menu bar app:      \(appRunning ? "running" : "not running")")
        print("  settings:          \(settingsURL.path)")
        print("  \(describe(h.hookStatus))")
        print("  hook executable:   \(paths.hookExecutable.path) [\(h.hookExecutablePresent ? "present" : "MISSING")]")
        print("  hooks executing:   \(h.hookLastRanAt.map { "last run \(Format.ago(now - $0))" } ?? "no run recorded")\(h.recentHookFailures > 0 ? ", \(h.recentHookFailures) recent failure(s)" : ", no recent failures")")
        print("  state directory:   \(paths.sessionsDir.path) [\(h.storeAccessible ? "accessible" : "NOT ACCESSIBLE")]")
        print("  last valid event:  \(h.lastEventAt.map { Format.ago(now - $0) } ?? "none yet")")
        print("  tracked sessions:  \(records.count)\(corrupt.isEmpty ? "" : " (\(corrupt.count) unreadable ignored)")")
        print("  coverage:          \(h.coverageText)")
        print("  background tasks:  \(h.backgroundVisibilityText)")
        for p in procs {
            print("    pid \(p.pid)  \(p.client.label.padding(toLength: 7, withPad: " ", startingAt: 0))  session \(mapping(p))")
        }
        for p in h.problems { print("  problem: \(p)") }
        if !unobserved.isEmpty {
            print("  note: an unobserved session is shown as Unknown until it fires its next hook event")
            print("        (its next prompt, tool call or the end of its current turn). Claude Code reloads")
            print("        hooks in running sessions, so no restart is needed.")
        }
    }
    exit(h.level == .error ? 2 : 0)

case "version", "--version", "-v":
    print("Claude Status \(ClaudeStatusVersion.current)")

case "report":
    let store = SessionStore(paths: paths)
    let (records, corrupt) = store.loadAll()
    let procs = ProcessInspector.detectSessions(now: now)
    let h = MonitoringHealth.check(paths: paths, settingsURL: settingsURL, records: records, corrupt: corrupt.count, processes: procs)
    let wake = SystemClock.lastWake()
    var sessions = records.map { Presentation.evaluate($0, now: now, alive: SessionMaintenance.liveness($0), lastWake: wake) }
    sessions += Presentation.unobservedSessions(Presentation.unobservedProcesses(procs, records: records), now: now)
    var versions: [Int32: String] = [:]
    for p in procs { versions[p.pid] = DiagnosticReport.clientVersion(fromExecutable: ProcessInspector.executablePath(p.pid)) }
    var uts = utsname()
    uname(&uts)
    let machine = withUnsafePointer(to: &uts.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) } }
    var input = DiagnosticReport.Input(
        version: ClaudeStatusVersion.current, osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        architecture: machine, health: h, appRunning: !NSRunningApplicationList.running().isEmpty,
        sessions: Presentation.sorted(sessions), processes: procs, processVersions: versions,
        hookLogTail: DiagnosticReport.readTail(paths.hookLog), settingsFileName: settingsURL.lastPathComponent, now: now)
    input.includeNames = flag("--include-names")
    input.sensitive = [NSUserName(), NSHomeDirectory(), NSFullUserName()].filter { !$0.isEmpty }
    let text = DiagnosticReport.render(input)
    if let out = option("--output") {
        do { try SessionStore.atomicWrite(Data(text.utf8), to: absURL(out), mode: 0o600) } catch { fail("\(error)") }
        print("Wrote sanitized report to \(out). Review it before attaching it to an issue.")
    } else {
        print(text)
    }

case "selftest":
    exit(SelfTest.run(hook: URL(fileURLWithPath: hookPath)) ? 0 : 1)

case "list":
    let (records, corrupt) = SessionStore(paths: paths).loadAll()
    var sessions = records.map { r in
        Presentation.evaluate(r, now: now, alive: SessionMaintenance.liveness(r), lastWake: SystemClock.lastWake())
    }
    let unobserved = Presentation.unobservedProcesses(ProcessInspector.detectSessions(now: now), records: records)
    sessions += Presentation.unobservedSessions(unobserved, now: now) { ProjectInfo.detect(from: $0) }
    sessions = Presentation.sorted(sessions)
    if flag("--json") {
        // Machine-readable, for acceptance tests: id prefixes and derived state only.
        let rows: [[String: Any]] = sessions.map { s in
            ["id": s.unobserved ? "pid-\(s.record.pid ?? 0)" : String(s.record.sessionId.prefix(8)),
             "state": s.state.rawValue, "label": s.label, "activity": s.activity.rawValue,
             "confidence": s.confidence.rawValue, "detail": s.detail, "client": s.record.client.rawValue,
             "foreground": s.foregroundSummary, "background": s.backgroundSummary,
             "backgroundActive": s.backgroundActive ?? NSNull(), "unobserved": s.unobserved, "dismissed": s.dismissed,
             "ended": s.ended, "processExited": s.processExited, "pid": s.record.pid.map { Int($0) } ?? NSNull(),
             "lastEvent": s.record.lastEventName, "silence": Int(s.silence)]
        }
        let agg = Presentation.aggregate(sessions)
        let obj: [String: Any] = ["aggregate": agg.rawValue, "activity": Presentation.aggregateActivity(sessions).rawValue,
                                  "summary": Presentation.summary(Presentation.counts(sessions)), "sessions": rows]
        print(String(decoding: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self))
        exit(0)
    }
    if sessions.isEmpty { print("No sessions tracked or detected.") }
    for s in sessions {
        let wt = s.record.worktreeName.map { " [\($0)]" } ?? ""
        let id = s.unobserved ? "pid \(s.record.pid ?? 0)" : String(s.record.sessionId.prefix(8))
        let hidden = s.dismissed ? " (hidden)" : ""
        print("\(id.padding(toLength: 9, withPad: " ", startingAt: 0)) \(s.label.padding(toLength: 24, withPad: " ", startingAt: 0)) \(s.record.client.label.padding(toLength: 7, withPad: " ", startingAt: 0)) \(s.record.displayName)\(wt)\(hidden) — \(s.detail) \(Presentation.timeText(s, now: now))")
        if s.showsDimensions {
            print("          foreground: \(s.foregroundSummary) · background: \(s.backgroundSummary)")
        }
    }
    if !corrupt.isEmpty { print("(\(corrupt.count) unreadable record(s) ignored)") }

case "clear-finished":
    let r = SessionMaintenance.cleanup(store: SessionStore(paths: paths), now: now, retention: nil,
                                       lastWake: SystemClock.lastWake(), alive: SessionMaintenance.liveness)
    print("Removed \(r.deleted) finished session record(s); hid \(r.dismissed) finished session(s) whose Claude process is still running.")

case "purge-state":
    guard flag("--yes") else { fail("purge-state deletes Claude Status history; pass --yes to confirm", code: 64) }
    let fm = FileManager.default
    var removed = 0
    // Remove only files Claude Status creates, by exact name pattern, never recursively.
    for (dir, match) in [(paths.sessionsDir, { (n: String) in n.hasSuffix(".json") || n == ".store.lock" || n.contains(".json.tmp.") }),
                         (paths.logsDir, { (n: String) in n.hasPrefix("hook.log") })] {
        for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where match(n) && !n.contains("/") {
            if unlink(dir.appendingPathComponent(n).path) == 0 { removed += 1 }
        }
        _ = rmdir(dir.path)
    }
    if flag("--include-backups") {
        for n in (try? fm.contentsOfDirectory(atPath: paths.backupsDir.path)) ?? [] where n.hasPrefix("settings.json.") && n.hasSuffix(".bak") {
            if unlink(paths.backupsDir.appendingPathComponent(n).path) == 0 { removed += 1 }
        }
        _ = rmdir(paths.backupsDir.path)
    }
    if unlink(paths.installManifest.path) == 0 { removed += 1 }
    print("Removed \(removed) Claude Status state file(s).")

case "-h", "--help", "help":
    print(usage)

default:
    fail("unknown command \(command)\n\(usage)", code: 64)
}

/// Detect the running menu bar app without AppKit: look for our executable by name.
enum NSRunningApplicationList {
    static func running() -> [Int32] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        return pids.prefix(Int(max(n, 0))).filter { pid in
            guard pid > 1, let p = ProcessInspector.executablePath(pid) else { return false }
            return p.hasSuffix("/Claude Status.app/Contents/MacOS/ClaudeStatus")
        }
    }
}

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
  diagnose           Print monitoring health (add --json for machine-readable output)
  list               List tracked sessions
  clear-finished     Remove non-active session records
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
    let h = MonitoringHealth.check(paths: paths, settingsURL: settingsURL, records: records, corrupt: corrupt.count)
    let appRunning = !NSRunningApplicationList.running().isEmpty
    if flag("--json") {
        let obj: [String: Any] = [
            "version": ClaudeStatusVersion.current,
            "level": h.level.rawValue,
            "hooks": h.hookStatus.kind.rawValue,
            "hookExecutablePresent": h.hookExecutablePresent,
            "storeAccessible": h.storeAccessible,
            "lastEventAt": h.lastEventAt ?? NSNull(),
            "sessions": records.count,
            "corruptRecords": corrupt.count,
            "unobservedClaudeProcesses": h.unobservedClaudeProcesses,
            "appRunning": appRunning,
            "problems": h.problems,
        ]
        let d = try! JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: d, as: UTF8.self))
    } else {
        print("Claude Status \(ClaudeStatusVersion.current) diagnostics")
        print("  health:            \(h.level.rawValue.uppercased()) — \(h.summary)")
        print("  settings:          \(settingsURL.path)")
        print("  \(describe(h.hookStatus))")
        print("  hook executable:   \(paths.hookExecutable.path) [\(h.hookExecutablePresent ? "present" : "MISSING")]")
        print("  state directory:   \(paths.sessionsDir.path) [\(h.storeAccessible ? "accessible" : "NOT ACCESSIBLE")]")
        print("  last valid event:  \(h.lastEventAt.map { Format.ago(now - $0) } ?? "none yet")")
        print("  tracked sessions:  \(records.count)\(corrupt.isEmpty ? "" : " (\(corrupt.count) unreadable ignored)")")
        print("  unobserved claude processes: \(h.unobservedClaudeProcesses) (sessions that have not fired a hook since installation)")
        print("  menu bar app:      \(appRunning ? "running" : "not running")")
        for p in h.problems { print("  problem: \(p)") }
    }
    exit(h.level == .error ? 2 : 0)

case "list":
    let (records, corrupt) = SessionStore(paths: paths).loadAll()
    let sessions = Presentation.sorted(records.map { r in
        Presentation.evaluate(r, now: now, alive: r.pid.map { ProcessInspector.isAlive(pid: $0, startTime: r.pidStartTime) }, lastWake: nil)
    })
    if sessions.isEmpty { print("No sessions tracked.") }
    for s in sessions {
        let wt = s.record.worktreeName.map { " [\($0)]" } ?? ""
        print("\(s.record.sessionId.prefix(8))  \(s.state.label.padding(toLength: 8, withPad: " ", startingAt: 0))  \(s.record.client.label.padding(toLength: 7, withPad: " ", startingAt: 0))  \(s.record.displayName)\(wt) — \(s.detail) \(Presentation.timeText(s, now: now))")
    }
    if !corrupt.isEmpty { print("(\(corrupt.count) unreadable record(s) ignored)") }

case "clear-finished":
    let store = SessionStore(paths: paths)
    var removed = 0
    try? store.withLock {
        let (records, corrupt) = store.loadAll()
        for r in records {
            let e = Presentation.evaluate(r, now: now, alive: r.pid.map { ProcessInspector.isAlive(pid: $0, startTime: r.pidStartTime) }, lastWake: nil)
            if Presentation.isRemovable(e, now: now, retention: nil) { try? store.delete(r.sessionId); removed += 1 }
        }
        for c in corrupt { store.deleteCorrupt(c) }
    }
    print("Removed \(removed) finished session record(s).")

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

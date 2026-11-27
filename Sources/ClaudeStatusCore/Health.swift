import Foundation

/// Monitoring health, kept separate from Claude session state.
public struct MonitoringHealth: Equatable, Sendable {
    public enum Level: String, Sendable { case ok, warning, error }

    public var hookStatus: HookInstallStatus
    public var hookExecutablePresent: Bool
    public var storeAccessible: Bool
    public var lastEventAt: Double?
    public var corruptRecords: Int
    public var unobservedClaudeProcesses: Int
    public var problems: [String]
    /// Running Claude Code processes found on this Mac (nil = not checked).
    public var runningClaudeProcesses: Int?
    /// Last time the hook executable ran (from its diagnostic log), any session.
    public var hookLastRanAt: Double?
    /// Hook runs among the most recent log entries that rejected or failed to store an event.
    public var recentHookFailures: Int = 0
    public var backgroundVisibility: BackgroundVisibility = .unconfirmed

    /// Whether Claude Code reports background tasks (`background_tasks` on Stop).
    public enum BackgroundVisibility: String, Sendable {
        /// At least one session's Stop / SubagentStop reported the array.
        case supported
        /// Turns finished, but none reported background work: this Claude Code version may not.
        case notReported
        /// No turn has finished since monitoring started.
        case unconfirmed
    }

    public init(hookStatus: HookInstallStatus, hookExecutablePresent: Bool, storeAccessible: Bool, lastEventAt: Double?,
                corruptRecords: Int, unobservedClaudeProcesses: Int, problems: [String]) {
        self.hookStatus = hookStatus; self.hookExecutablePresent = hookExecutablePresent
        self.storeAccessible = storeAccessible; self.lastEventAt = lastEventAt; self.corruptRecords = corruptRecords
        self.unobservedClaudeProcesses = unobservedClaudeProcesses; self.problems = problems
    }

    public var hooksInstalled: Bool { hookStatus.kind == .installed || hookStatus.kind == .partial }
    public var coverageComplete: Bool { unobservedClaudeProcesses == 0 }

    /// "3 of 4 running sessions observed"
    public var coverageText: String {
        guard let n = runningClaudeProcesses else { return "Coverage not checked" }
        if n == 0 { return "No Claude Code sessions running" }
        let observed = max(n - unobservedClaudeProcesses, 0)
        return "\(observed) of \(n) running session\(n == 1 ? "" : "s") observed"
    }

    /// "Hooks installed · last ran 12s ago · 0 rejected"
    public func hooksText(now: Double) -> String {
        let inst = hooksInstalled ? (hookStatus.kind == .partial ? "Hooks partly installed" : "Hooks installed") : "Hooks not installed"
        let ran = hookLastRanAt.map { "last ran \(Format.ago(now - $0))" } ?? "no run recorded"
        return "\(inst) · \(ran) · \(recentHookFailures) rejected"
    }

    public var backgroundVisibilityText: String {
        switch backgroundVisibility {
        case .supported: return "Background tasks reported by Claude Code"
        case .notReported: return "Background tasks not reported by this Claude Code version"
        case .unconfirmed: return "Background task reporting not yet confirmed"
        }
    }

    public var level: Level {
        if !hookExecutablePresent || !storeAccessible || hookStatus.kind == .invalidSettings || hookStatus.kind == .notInstalled
            || hookStatus.kind == .settingsMissing { return .error }
        if !problems.isEmpty { return .warning }
        return .ok
    }

    public var summary: String {
        switch level {
        case .ok:
            if let n = runningClaudeProcesses, n > 0 { return "Monitoring all \(n) running session\(n == 1 ? "" : "s")" }
            return "Monitoring active"
        case .warning: return problems.first ?? "Monitoring degraded"
        case .error: return problems.first ?? "Monitoring unavailable"
        }
    }

    public static func check(paths: StatusPaths, settingsURL: URL, records: [SessionRecord], corrupt: Int,
                             checkProcesses: Bool = true, processes: [DetectedProcess]? = nil) -> MonitoringHealth {
        let fm = FileManager.default
        let conf = HookConfigurator(settingsURL: settingsURL, hookCommandPath: paths.hookExecutable.path,
                                    backupsDir: paths.backupsDir)
        let status = conf.status()
        let exe = fm.isExecutableFile(atPath: paths.hookExecutable.path)
        var dirOK = false
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: paths.sessionsDir.path, isDirectory: &isDir), isDir.boolValue {
            dirOK = fm.isWritableFile(atPath: paths.sessionsDir.path) && fm.isReadableFile(atPath: paths.sessionsDir.path)
        } else if !fm.fileExists(atPath: paths.sessionsDir.path) {
            dirOK = fm.isWritableFile(atPath: paths.root.path) || !fm.fileExists(atPath: paths.root.path)
        }
        var last = records.map(\.lastEventAt).max()
        var hookRan: Double? = nil
        if let attrs = try? fm.attributesOfItem(atPath: paths.hookLog.path), let m = attrs[.modificationDate] as? Date {
            hookRan = m.timeIntervalSince1970
            last = max(last ?? 0, m.timeIntervalSince1970)
        }
        let failures = recentFailures(in: paths.hookLog)
        var unobserved = 0
        var running: Int? = nil
        if checkProcesses || processes != nil {
            let procs = processes ?? ProcessInspector.detectSessions()
            running = procs.count
            unobserved = Presentation.unobservedProcesses(procs, records: records).count
        }
        let visibility: BackgroundVisibility
        if records.contains(where: { $0.backgroundReportedAt != nil }) { visibility = .supported }
        else if records.contains(where: { $0.lastCompletedAt != nil }) { visibility = .notReported }
        else { visibility = .unconfirmed }
        var problems: [String] = []
        switch status.kind {
        case .installed: break
        case .partial: problems.append("Hooks partially installed (missing \(status.missingEvents.joined(separator: ", ")))")
        case .notInstalled: problems.append("Claude Status hooks are not installed")
        case .settingsMissing: problems.append("~/.claude/settings.json not found")
        case .invalidSettings: problems.append("Claude settings could not be parsed")
        }
        if !status.duplicateEvents.isEmpty { problems.append("Duplicate hook registrations") }
        if status.mismatchedCommand { problems.append("Hook command points to a different location") }
        if !exe { problems.insert("Hook executable missing", at: 0) }
        if !dirOK { problems.insert("State directory not accessible", at: 0) }
        if corrupt > 0 { problems.append("\(corrupt) unreadable session record\(corrupt == 1 ? "" : "s") ignored") }
        if failures > 0 { problems.append("\(failures) recent hook event\(failures == 1 ? " was" : "s were") rejected or not stored (see diagnostics)") }
        // Detected sessions without a hook event are a coverage gap, never silently "active".
        if unobserved > 0, let n = running {
            problems.append("Monitoring incomplete: \(unobserved) of \(n) running session\(n == 1 ? "" : "s") not yet observed")
        }
        if visibility == .notReported { problems.append("Background tasks are not reported by this Claude Code version") }
        var h = MonitoringHealth(hookStatus: status, hookExecutablePresent: exe, storeAccessible: dirOK,
                                 lastEventAt: last, corruptRecords: corrupt, unobservedClaudeProcesses: unobserved,
                                 problems: problems)
        h.runningClaudeProcesses = running
        h.hookLastRanAt = hookRan
        h.recentHookFailures = failures
        h.backgroundVisibility = visibility
        return h
    }

    /// Count non-accepted results among the last 200 hook log lines.
    /// Line format: `<iso> <event> <sid8> <result> <micros>us ...`.
    public static func recentFailures(in log: URL, lines: Int = 200) -> Int {
        guard let fh = try? FileHandle(forReadingFrom: log) else { return 0 }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? fh.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? fh.readToEnd(), let text = String(data: data, encoding: .utf8) else { return 0 }
        let tail = text.split(separator: "\n").suffix(lines)
        return tail.filter { line in
            let f = line.split(separator: " ")
            guard f.count >= 4 else { return false }
            return f[3].hasPrefix("rejected") || f[3].hasPrefix("store:")
        }.count
    }
}

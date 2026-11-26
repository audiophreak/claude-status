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

    public init(hookStatus: HookInstallStatus, hookExecutablePresent: Bool, storeAccessible: Bool, lastEventAt: Double?,
                corruptRecords: Int, unobservedClaudeProcesses: Int, problems: [String]) {
        self.hookStatus = hookStatus; self.hookExecutablePresent = hookExecutablePresent
        self.storeAccessible = storeAccessible; self.lastEventAt = lastEventAt; self.corruptRecords = corruptRecords
        self.unobservedClaudeProcesses = unobservedClaudeProcesses; self.problems = problems
    }

    public var level: Level {
        if !hookExecutablePresent || !storeAccessible || hookStatus.kind == .invalidSettings || hookStatus.kind == .notInstalled
            || hookStatus.kind == .settingsMissing { return .error }
        if !problems.isEmpty { return .warning }
        return .ok
    }

    public var summary: String {
        switch level {
        case .ok: return "Monitoring active"
        case .warning: return problems.first ?? "Monitoring degraded"
        case .error: return problems.first ?? "Monitoring unavailable"
        }
    }

    public static func check(paths: StatusPaths, settingsURL: URL, records: [SessionRecord], corrupt: Int,
                             checkProcesses: Bool = true) -> MonitoringHealth {
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
        if let attrs = try? fm.attributesOfItem(atPath: paths.hookLog.path), let m = attrs[.modificationDate] as? Date {
            last = max(last ?? 0, m.timeIntervalSince1970)
        }
        var unobserved = 0
        if checkProcesses {
            let known = Set(records.filter { !$0.ended }.compactMap(\.pid))
            unobserved = ProcessInspector.claudeProcesses().filter { !known.contains($0.pid) }.count
        }
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
        // Unobserved processes are informational: sessions started before installation or
        // sessions that have not fired a hook yet. Not a monitoring failure.
        return MonitoringHealth(hookStatus: status, hookExecutablePresent: exe, storeAccessible: dirOK,
                                lastEventAt: last, corruptRecords: corrupt, unobservedClaudeProcesses: unobserved,
                                problems: problems)
    }
}

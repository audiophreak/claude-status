import Foundation

/// Sanitized diagnostic report for bug reports (`claude-status-ctl report`).
///
/// By default it contains no session identifiers (sessions are numbered), no project or
/// repository names, no filesystem paths, no user name and nothing from hook payloads
/// (Claude Status never stores prompts, tool input/output or transcripts in the first
/// place). A final scrubbing pass removes anything path-, user- or identifier-shaped that
/// slipped through. `includeNames` opts in to project names; paths are never included.
public struct DiagnosticReport {
    public struct Input {
        public var version: String
        public var osVersion: String
        public var architecture: String
        public var health: MonitoringHealth
        public var appRunning: Bool
        public var sessions: [EffectiveSession]
        public var processes: [DetectedProcess]
        public var processVersions: [Int32: String]
        public var hookLogTail: String
        public var settingsFileName: String
        public var now: Double
        public var includeNames = false
        /// Strings that must never appear (user name, home directory, ...).
        public var sensitive: [String] = []

        public init(version: String, osVersion: String, architecture: String, health: MonitoringHealth, appRunning: Bool,
                    sessions: [EffectiveSession], processes: [DetectedProcess], processVersions: [Int32: String],
                    hookLogTail: String, settingsFileName: String, now: Double) {
            self.version = version; self.osVersion = osVersion; self.architecture = architecture; self.health = health
            self.appRunning = appRunning; self.sessions = sessions; self.processes = processes
            self.processVersions = processVersions; self.hookLogTail = hookLogTail
            self.settingsFileName = settingsFileName; self.now = now
        }
    }

    /// Claude Code version from an executable path (`…/claude-code/2.1.330/…` or
    /// `…/versions/2.1.325`). Only the version number is kept.
    public static func clientVersion(fromExecutable path: String?) -> String? {
        guard let path else { return nil }
        let comps = path.split(separator: "/").map(String.init)
        for c in comps.reversed() where isVersion(c) { return c }
        return nil
    }

    static func isVersion(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return (2...4).contains(parts.count) && parts.allSatisfy { !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isNumber) }
    }

    /// Last `bytes` of a log file as text (whole lines only).
    public static func readTail(_ url: URL, bytes: UInt64 = 64 * 1024) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        try? fh.seek(toOffset: size > bytes ? size - bytes : 0)
        guard let d = try? fh.readToEnd() else { return "" }
        var t = String(decoding: d, as: UTF8.self)
        if size > bytes, let nl = t.firstIndex(of: "\n") { t = String(t[t.index(after: nl)...]) }
        return t
    }

    /// Summary of the hook log tail: per event, result counts and latency. The session-id
    /// prefixes and byte counts in the log are dropped.
    public static func summarizeLog(_ text: String) -> (lines: [String], total: Int) {
        var perEvent: [String: (ok: Int, other: [String: Int], micros: [Int])] = [:]
        var total = 0
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ")
            guard f.count >= 5 else { continue }
            let event = Validate.token(String(f[1]), maxLength: 40) ? String(f[1]) : "?"
            let result = String(f[3].prefix(40)).replacingOccurrences(of: "\"", with: "")
            var entry = perEvent[event] ?? (0, [:], [])
            if result == "ok" { entry.ok += 1 } else {
                // keep the category only (e.g. "rejected:malformedJSON", "store:lockTimeout")
                let cat = result.split(separator: "(").first.map(String.init) ?? result
                entry.other[cat, default: 0] += 1
            }
            if f[4].hasSuffix("us"), let us = Int(f[4].dropLast(2)) { entry.micros.append(us) }
            perEvent[event] = entry
            total += 1
        }
        let lines = perEvent.keys.sorted().map { k -> String in
            let e = perEvent[k]!
            let sorted = e.micros.sorted()
            let p50 = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            let p95 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            let other = e.other.keys.sorted().map { "\($0)×\(e.other[$0]!)" }.joined(separator: ", ")
            return "| \(k) | \(e.ok) | \(other.isEmpty ? "—" : other) | \(p50 / 1000).\(p50 % 1000 / 100) ms | \(p95 / 1000).\(p95 % 1000 / 100) ms |"
        }
        return (lines, total)
    }

    public static func render(_ i: Input) -> String {
        var out: [String] = []
        let h = i.health
        out.append("## Claude Status diagnostic report")
        out.append("")
        out.append("Sanitized: no session identifiers, \(i.includeNames ? "project names included (--include-names)" : "no project names"), no paths, no prompts, tool data or transcripts.")
        out.append("")
        out.append("| Item | Value |")
        out.append("|---|---|")
        out.append("| Claude Status | \(i.version) |")
        out.append("| macOS | \(i.osVersion) (\(i.architecture)) |")
        out.append("| Monitoring health | \(h.level.rawValue) — \(h.summary) |")
        out.append("| Menu bar app | \(i.appRunning ? "running" : "not running") |")
        out.append("| Hooks | \(h.hookStatus.kind.rawValue)\(h.hookStatus.missingEvents.isEmpty || h.hookStatus.kind == .notInstalled ? "" : " (missing \(h.hookStatus.missingEvents.joined(separator: ", ")))")\(h.hookStatus.duplicateEvents.isEmpty ? "" : " (duplicates)")\(h.hookStatus.mismatchedCommand ? " (command mismatch)" : "") in \(i.settingsFileName) |")
        out.append("| Hook executable | \(h.hookExecutablePresent ? "present" : "missing") |")
        out.append("| Hooks executing | \(h.hookLastRanAt.map { "last run \(Format.ago(i.now - $0))" } ?? "no run recorded"), \(h.recentHookFailures) recent failure(s) |")
        out.append("| Event ingestion | \(h.storeAccessible ? "state directory accessible" : "STATE DIRECTORY NOT ACCESSIBLE"), last valid event \(h.lastEventAt.map { Format.ago(i.now - $0) } ?? "none") |")
        out.append("| Coverage | \(h.coverageText) |")
        out.append("| Background tasks | \(h.backgroundVisibilityText) |")
        out.append("| Unreadable records | \(h.corruptRecords) |")
        out.append("")
        if !h.problems.isEmpty {
            out.append("**Problems**")
            out.append("")
            for p in h.problems { out.append("- \(p)") }
            out.append("")
        }
        // Running Claude Code clients (version numbers only).
        var clients: [String: Int] = [:]
        for p in i.processes {
            let v = i.processVersions[p.pid] ?? "unknown version"
            clients["\(p.client.label) \(v)", default: 0] += 1
        }
        if !clients.isEmpty {
            out.append("**Running Claude Code processes:** " + clients.keys.sorted().map { "\($0) ×\(clients[$0]!)" }.joined(separator: ", "))
            out.append("")
        }
        // Sessions, numbered; names only with --include-names.
        let shown = i.sessions.filter { !$0.ended }
        out.append("**Sessions** (\(shown.count) not ended, \(i.sessions.count - shown.count) ended)")
        out.append("")
        if !shown.isEmpty {
            out.append("| # | Client | Status | Foreground | Background | Confidence | Last event | Process |")
            out.append("|---|---|---|---|---|---|---|---|")
            var projects: [String: Int] = [:]
            for (n, s) in shown.enumerated() {
                var label = "S\(n + 1)"
                if i.includeNames {
                    label += " " + s.record.displayName
                } else {
                    let key = s.record.displayName
                    if projects[key] == nil { projects[key] = projects.count + 1 }
                    label += " (project \(projects[key]!))"
                }
                let last = s.unobserved ? "none" : "\(s.record.lastEventName) \(Format.ago(s.silence))"
                let proc = s.unobserved ? "running, unobserved" : (s.processExited ? "exited" : (s.record.pid == nil ? "not recorded" : "running"))
                out.append("| \(label) | \(s.record.client.label) | \(s.label) | \(s.foregroundSummary) | \(s.backgroundSummary) | \(s.confidence.rawValue) | \(last) | \(proc) |")
            }
            out.append("")
        }
        let (logLines, total) = summarizeLog(i.hookLogTail)
        out.append("**Hook log** (last \(total) runs; session identifiers removed)")
        out.append("")
        if logLines.isEmpty { out.append("No hook runs recorded.") } else {
            out.append("| Event | Accepted | Other results | Median latency | p95 latency |")
            out.append("|---|---|---|---|---|")
            out.append(contentsOf: logLines)
        }
        out.append("")
        var sensitive = i.sensitive
        if !i.includeNames {
            for s in i.sessions {
                let r = s.record
                for n in [r.displayName, r.projectName, r.gitRepoName, r.worktreeName, r.cwd.map { ($0 as NSString).lastPathComponent }]
                    .compactMap({ $0 }) where n.count >= 3 && !genericNames.contains(n.lowercased()) {
                    sensitive.append(n)
                }
            }
        }
        return scrub(out.joined(separator: "\n"), sensitive: sensitive)
    }

    /// Folder names too generic to identify a project, which also occur in the report text.
    static let genericNames: Set<String> = ["claude", "desktop", "status", "session", "sessions", "cli", "code",
                                            "developer", "documents", "projects", "project", "src", "tmp", "home",
                                            "users", "library", "running", "unknown", "working", "background"]

    /// Defence in depth: remove anything path-, user- or identifier-shaped.
    public static func scrub(_ text: String, sensitive: [String]) -> String {
        var s = text
        for v in Set(sensitive).sorted(by: { $0.count > $1.count }) where v.count >= 3 {
            s = s.replacingOccurrences(of: v, with: "<redacted>")
        }
        let patterns = [
            // absolute paths under user/private locations
            #"(/Users|/home|/private|/var/folders|/Volumes)/[^\s|)]*"#,
            // UUIDs and long hex identifiers (session ids, hashes)
            #"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b"#,
            #"\b[0-9a-fA-F]{16,}\b"#,
            // e-mail addresses
            #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
        ]
        for p in patterns {
            if let re = try? NSRegularExpression(pattern: p) {
                s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "<redacted>")
            }
        }
        return s
    }
}

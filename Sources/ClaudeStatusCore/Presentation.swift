import Foundation

/// Time-dependent interpretation of stored records. Pure, so it is unit-testable.
public struct PresentationPolicy: Sendable, Equatable {
    /// Working with no event for this long while no tool is executing -> Unknown (stale).
    public var staleAfterNoToolSeconds: Double = 20 * 60
    /// Working with a tool in flight (long builds, tests) tolerates a longer silence.
    public var staleAfterToolSeconds: Double = 120 * 60
    /// Background work reported by Claude Code with no later event for this long -> Unknown.
    /// Background commands (builds, rehearsals, test suites) legitimately run for hours.
    public var staleAfterBackgroundSeconds: Double = 8 * 3600
    public init() {}
}

/// What kind of work a Working session is doing.
public enum Activity: String, Sendable, Equatable {
    case none
    /// A foreground turn is running (Claude is responding or running a tool).
    case foreground
    /// The response finished but Claude Code reports background tasks still running.
    case background
    /// The response finished and a one-shot scheduled wakeup will continue the session.
    case scheduled
}

/// How well the displayed state is supported by evidence.
public enum Confidence: String, Sendable, Equatable {
    /// Every dimension was reported by documented hook events.
    case confirmed
    /// Observed mid-turn or mid-session: the state is right but some history is missing.
    case partial
    /// The state cannot be determined (not observed, not reported, stale, process gone).
    case unknown
}

public struct EffectiveSession: Equatable, Sendable, Identifiable {
    public var id: String { record.sessionId }
    public var record: SessionRecord
    public var state: SessionState
    public var activity: Activity = .none
    public var confidence: Confidence = .confirmed
    public var detail: String
    public var processExited: Bool
    public var stale: Bool
    public var ended: Bool
    /// A running Claude process that has not delivered a hook event to Claude Status.
    public var unobserved: Bool = false
    /// Hidden by "Clear Finished" (process still running).
    public var dismissed: Bool = false
    /// Active background tasks at the last report; nil = not reported.
    public var backgroundActive: Int?

    public init(record: SessionRecord, state: SessionState, detail: String, processExited: Bool = false,
                stale: Bool = false, ended: Bool = false) {
        self.record = record; self.state = state; self.detail = detail
        self.processExited = processExited; self.stale = stale; self.ended = ended
    }

    /// Status label, e.g. "Working", "Working — Background", "Unknown — Not observed".
    public var label: String {
        if unobserved { return "Unknown — Not observed" }
        switch (state, activity) {
        case (.working, .background): return "Working — Background"
        case (.working, .scheduled): return "Working — Continuation scheduled"
        case (.working, _) where record.reason == .autoContinued: return "Working — Continuing"
        default: return state.label
        }
    }

    /// Foreground turn, independently of background work.
    public var foregroundSummary: String {
        if unobserved { return "Not observed" }
        if ended { return "Session ended" }
        switch record.state {
        case .working: return record.inFlightTools.isEmpty ? "Responding" : "Running tool"
        case .waiting: return "Waiting for you"
        case .complete: return "Response finished"
        case .error: return record.reason == .interrupted ? "Interrupted" : "Ended with an API error"
        case .idle: return "No prompt yet"
        case .unknown: return "Not yet observed"
        }
    }

    /// Background work, independently of the foreground turn.
    public var backgroundSummary: String {
        if unobserved { return "Unknown" }
        guard let tasks = record.activeBackground else { return "Not reported" }
        var parts: [String] = []
        if !tasks.isEmpty {
            let types = Presentation.typeSummary(tasks)
            parts.append("\(tasks.count) task\(tasks.count == 1 ? "" : "s") running (\(types))")
        }
        if let sc = record.schedules, sc.oneShot > 0 {
            parts.append("\(sc.oneShot) wakeup\(sc.oneShot == 1 ? "" : "s") scheduled")
        }
        return parts.isEmpty ? "None" : parts.joined(separator: " · ")
    }

    /// Whether to show separate foreground / background lines in the dashboard.
    public var showsDimensions: Bool {
        guard !unobserved, !ended else { return false }
        return activity == .background || activity == .scheduled
            || (state == .working && record.activeBackground?.isEmpty == false)
    }
}

/// A running Claude Code process found with libproc (no Claude internals are read).
public struct DetectedProcess: Equatable, Sendable {
    public var pid: Int32
    public var startTime: Double
    public var client: ClientType
    public var cwd: String?
    public init(pid: Int32, startTime: Double, client: ClientType, cwd: String?) {
        self.pid = pid; self.startTime = startTime; self.client = client; self.cwd = cwd
    }
}

public enum Presentation {
    /// - Parameters:
    ///   - alive: process liveness (nil = unknown / no PID recorded).
    ///   - lastWake: most recent system wake; silence during sleep is not counted.
    public static func evaluate(_ r: SessionRecord, now: Double, alive: Bool?, lastWake: Double?,
                                policy: PresentationPolicy = PresentationPolicy()) -> EffectiveSession {
        var e = EffectiveSession(record: r, state: r.state, detail: baseDetail(r), ended: r.ended)
        e.dismissed = r.dismissed == true
        e.backgroundActive = r.activeBackground?.count
        if r.ended {
            e.state = .idle
            e.detail = "Session ended"
            return e
        }
        derive(&e, now: now, lastWake: lastWake, policy: policy)
        if alive == false {
            e.processExited = true
            let foregroundFinished = r.state == .complete || r.state == .error || r.state == .idle
            let backgroundPending = e.activity == .background || e.activity == .scheduled
            e.activity = .none
            if foregroundFinished && !backgroundPending {
                e.ended = true
                e.state = .idle
                e.detail = "Session ended (process exited)"
            } else {
                e.state = .unknown
                e.confidence = .unknown
                e.detail = backgroundPending
                    ? "Claude process exited while background work was reported running"
                    : "Claude process exited without ending the session"
            }
        }
        return e
    }

    /// Combine the foreground turn with background work and staleness.
    static func derive(_ e: inout EffectiveSession, now: Double, lastWake: Double?, policy: PresentationPolicy) {
        let r = e.record
        let silence = now - max(r.lastEventAt, lastWake ?? 0)
        let bg = r.activeBackground
        let wakeups = r.schedules?.oneShot ?? 0
        if r.observedMidSession || r.reason == .observedMidTurn { e.confidence = .partial }
        switch r.state {
        case .working:
            e.activity = .foreground
            let limit = r.inFlightTools.isEmpty ? policy.staleAfterNoToolSeconds : policy.staleAfterToolSeconds
            if silence > limit {
                e.state = .unknown
                e.activity = .none
                e.stale = true
                e.confidence = .unknown
                e.detail = "No activity for \(Format.duration(silence)) (possibly interrupted)"
            }
        case .complete:
            if let bg, !bg.isEmpty {
                e.state = .working
                e.activity = .background
                e.detail = "\(bg.count) background task\(bg.count == 1 ? "" : "s") running (\(typeSummary(bg)))"
            } else if wakeups > 0 {
                e.state = .working
                e.activity = .scheduled
                e.detail = "Claude will continue at a scheduled wakeup"
            } else if bg == nil {
                e.state = .unknown
                e.confidence = .unknown
                e.detail = "Response finished · background work not reported by Claude Code"
            }
            if e.activity == .background || e.activity == .scheduled, silence > policy.staleAfterBackgroundSeconds {
                e.state = .unknown
                e.activity = .none
                e.stale = true
                e.confidence = .unknown
                e.detail = "Background work not confirmed for \(Format.duration(silence))"
            }
        case .waiting, .error:
            if let bg, !bg.isEmpty { e.detail += " · \(bg.count) background task\(bg.count == 1 ? "" : "s")" }
        case .idle, .unknown:
            break
        }
        if r.state == .unknown { e.confidence = .unknown }
    }

    static func typeSummary(_ tasks: [BackgroundTaskInfo]) -> String {
        var counts: [(String, Int)] = []
        for t in tasks {
            if let i = counts.firstIndex(where: { $0.0 == t.type }) { counts[i].1 += 1 } else { counts.append((t.type, 1)) }
        }
        return counts.map { $0.1 == 1 ? $0.0 : "\($0.1) \($0.0)" }.joined(separator: ", ")
    }

    static func baseDetail(_ r: SessionRecord) -> String {
        switch r.state {
        case .working:
            var s: String
            switch r.reason {
            case .continued: s = "Continuing"
            case .autoContinued: s = "Resumed automatically after background work"
            default: s = r.inFlightTools.isEmpty ? "Thinking" : "Running tool"
            }
            if r.activeSubagents > 0 { s += " · \(r.activeSubagents) subagent\(r.activeSubagents == 1 ? "" : "s")" }
            if let bg = r.activeBackground, !bg.isEmpty { s += " · \(bg.count) background task\(bg.count == 1 ? "" : "s")" }
            return s
        case .waiting:
            switch r.reason {
            case .permission: return "Approval required"
            case .question: return "Question for you"
            case .planApproval: return "Plan approval required"
            case .elicitation: return "Input requested"
            case .idleInput: return "Waiting for input (turn ended without completion)"
            default: return "Input required"
            }
        case .complete:
            if let sc = r.schedules, sc.recurring > 0 {
                return "Ready for next prompt · \(sc.recurring) recurring schedule\(sc.recurring == 1 ? "" : "s")"
            }
            return "Ready for next prompt"
        case .error:
            if r.reason == .interrupted { return "Interrupted" }
            return "API error: \(r.errorCategory ?? "unknown")"
        case .idle:
            return r.reason == .resumed ? "Resumed · no prompt yet" : "Started · no prompt yet"
        case .unknown:
            return "State not yet observed"
        }
    }

    // MARK: Existing-session discovery

    /// Running Claude processes that no live, non-ended record accounts for. Records are
    /// matched by PID (with start time, so a reused PID never matches); a record without a
    /// PID matches a process with the same working directory.
    public static func unobservedProcesses(_ processes: [DetectedProcess], records: [SessionRecord]) -> [DetectedProcess] {
        let live = records.filter { !$0.ended }
        var pidless = live.filter { $0.pid == nil }
        return processes.filter { p in
            if live.contains(where: { r in
                guard r.pid == p.pid else { return false }
                guard let st = r.pidStartTime else { return true }
                return abs(st - p.startTime) < 1.0
            }) { return false }
            if let cwd = p.cwd, let i = pidless.firstIndex(where: { $0.cwd == cwd }) {
                pidless.remove(at: i)
                return false
            }
            return true
        }
    }

    /// Placeholder rows for unobserved processes: always Unknown, never omitted.
    public static func unobservedSessions(_ processes: [DetectedProcess], now: Double,
                                          projectInfo: ((String) -> ProjectInfo?)? = nil) -> [EffectiveSession] {
        processes.map { p in
            var r = SessionRecord(sessionId: "pid-\(p.pid)", timestamp: p.startTime)
            r.client = p.client
            r.pid = p.pid
            r.pidStartTime = p.startTime
            r.cwd = p.cwd
            if let cwd = p.cwd, let info = projectInfo?(cwd) {
                r.gitRepoName = info.repoName
                r.worktreeName = info.worktreeName
            }
            r.projectName = r.displayName
            var e = EffectiveSession(record: r, state: .unknown,
                                     detail: "No hook event received yet; its state appears with the next one")
            e.unobserved = true
            e.confidence = .unknown
            return e
        }
    }

    // MARK: Aggregation

    /// Sessions that count towards the menu bar and summary.
    static func counted(_ sessions: [EffectiveSession]) -> [EffectiveSession] {
        sessions.filter { !$0.ended && !$0.dismissed }
    }

    /// Aggregate precedence: Waiting > Error > Working > Unknown > Complete > Idle.
    /// Unobserved sessions count as Unknown, so detected-but-unknown work is never hidden.
    public static func aggregate(_ sessions: [EffectiveSession]) -> SessionState {
        counted(sessions).map(\.state).min(by: { $0.precedence < $1.precedence }) ?? .idle
    }

    /// Working activity for the aggregate indicator: `.background` only when every working
    /// session is doing background work only.
    public static func aggregateActivity(_ sessions: [EffectiveSession]) -> Activity {
        let working = counted(sessions).filter { $0.state == .working }
        if working.isEmpty { return .none }
        if working.contains(where: { $0.activity == .foreground }) { return .foreground }
        if working.contains(where: { $0.activity == .background }) { return .background }
        return .scheduled
    }

    public struct Counts: Equatable, Sendable {
        public var working = 0, waiting = 0, error = 0, complete = 0, unknown = 0, idle = 0
        /// Subsets of `working` / `unknown`.
        public var background = 0, unobserved = 0
        public init() {}
        public var active: Int { working + waiting }
    }

    public static func counts(_ sessions: [EffectiveSession]) -> Counts {
        var c = Counts()
        for s in counted(sessions) {
            switch s.state {
            case .working:
                c.working += 1
                if s.activity == .background || s.activity == .scheduled { c.background += 1 }
            case .waiting: c.waiting += 1
            case .error: c.error += 1
            case .complete: c.complete += 1
            case .unknown:
                c.unknown += 1
                if s.unobserved { c.unobserved += 1 }
            case .idle: c.idle += 1
            }
        }
        return c
    }

    /// One-line summary for the dashboard header. Never claims "nothing running" while a
    /// detected session's state is unknown.
    public static func summary(_ c: Counts) -> String {
        var parts: [String] = []
        if c.waiting > 0 { parts.append("\(c.waiting) waiting") }
        if c.error > 0 { parts.append("\(c.error) error") }
        let fg = c.working - c.background
        if fg > 0 { parts.append("\(fg) working") }
        if c.background > 0 { parts.append("\(c.background) background") }
        if c.unknown > 0 { parts.append("\(c.unknown) unknown") }
        if c.complete > 0 { parts.append("\(c.complete) complete") }
        if parts.isEmpty { return c.idle > 0 ? "\(c.idle) idle" : "No sessions detected" }
        return parts.joined(separator: " · ")
    }

    /// Sort: attention first, then working, then most recent activity.
    public static func sorted(_ sessions: [EffectiveSession]) -> [EffectiveSession] {
        sessions.sorted {
            let a = ($0.ended || $0.dismissed) ? 9 : $0.state.precedence, b = ($1.ended || $1.dismissed) ? 9 : $1.state.precedence
            if a != b { return a < b }
            return $0.record.lastEventAt > $1.record.lastEventAt
        }
    }

    /// Sessions eligible for removal by retention cleanup or "Clear finished".
    /// Working (foreground or background), Waiting and undetermined sessions never are.
    public static func isRemovable(_ s: EffectiveSession, now: Double, retention: Double?) -> Bool {
        if s.unobserved { return false }
        if s.state.isActive { return false }
        if s.state == .unknown && !s.processExited && !s.stale && !s.ended { return false }
        guard let retention else { return true }   // explicit clear
        return now - s.record.lastEventAt > retention
    }

    public enum Cleanup: Equatable { case keep, dismiss, delete }

    /// A removable session whose Claude process is still running is hidden, not deleted, so
    /// the process stays correlated with its record and is never reported as unobserved.
    public static func cleanupAction(_ s: EffectiveSession, alive: Bool?, now: Double, retention: Double?) -> Cleanup {
        guard isRemovable(s, now: now, retention: retention) else { return .keep }
        if !s.ended && alive != false && s.record.pid != nil { return s.dismissed ? .keep : .dismiss }
        return .delete
    }

    public static func timeText(_ s: EffectiveSession, now: Double) -> String {
        let r = s.record
        if s.unobserved { return "running " + Format.duration(now - r.firstSeenAt) }
        switch s.state {
        case .working where s.activity == .background || s.activity == .scheduled:
            return r.lastCompletedAt.map { "replied " + Format.ago(now - $0) } ?? ""
        case .working, .waiting:
            if let t = r.turnStartedAt {
                return (r.turnObservedFromStart ? "" : "≥ ") + Format.clock(now - t)
            }
            return ""
        case .complete:
            var t = r.lastCompletedAt.map { Format.ago(now - $0) } ?? ""
            if let d = r.lastTurnDuration { t += " · took \(r.lastTurnDurationExact ? "" : "≥ ")\(Format.duration(d))" }
            return t
        default:
            return Format.ago(now - r.lastEventAt)
        }
    }
}

public enum Format {
    /// "12m 34s", "1h 05m", "45s"
    public static func clock(_ secs: Double) -> String {
        let s = max(0, Int(secs))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(String(format: "%02d", s % 60))s" }
        return "\(s / 3600)h \(String(format: "%02d", (s % 3600) / 60))m"
    }

    /// Coarse duration: "45s", "12m", "3h 5m", "2d 4h"
    public static func duration(_ secs: Double) -> String {
        let s = max(0, Int(secs))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { let m = (s % 3600) / 60; return m == 0 ? "\(s / 3600)h" : "\(s / 3600)h \(m)m" }
        let h = (s % 86400) / 3600
        return h == 0 ? "\(s / 86400)d" : "\(s / 86400)d \(h)h"
    }

    public static func ago(_ secs: Double) -> String {
        secs < 10 ? "just now" : "\(duration(secs)) ago"
    }
}

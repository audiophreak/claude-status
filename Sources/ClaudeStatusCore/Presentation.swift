import Foundation

/// Time-dependent interpretation of stored records. Pure, so it is unit-testable.
public struct PresentationPolicy: Sendable, Equatable {
    /// Working with no event for this long while no tool is executing -> Unknown (stale).
    public var staleAfterNoToolSeconds: Double = 20 * 60
    /// Working with a tool in flight (long builds, tests) tolerates a longer silence.
    public var staleAfterToolSeconds: Double = 120 * 60
    public init() {}
}

public struct EffectiveSession: Equatable, Sendable, Identifiable {
    public var id: String { record.sessionId }
    public var record: SessionRecord
    public var state: SessionState
    public var detail: String
    public var processExited: Bool
    public var stale: Bool
    public var ended: Bool
}

public enum Presentation {
    /// - Parameters:
    ///   - alive: process liveness (nil = unknown / no PID recorded).
    ///   - lastWake: most recent system wake; silence during sleep is not counted.
    public static func evaluate(_ r: SessionRecord, now: Double, alive: Bool?, lastWake: Double?,
                                policy: PresentationPolicy = PresentationPolicy()) -> EffectiveSession {
        var e = EffectiveSession(record: r, state: r.state, detail: baseDetail(r), processExited: false, stale: false, ended: r.ended)
        if r.ended {
            e.state = .idle
            e.detail = "Session ended"
            return e
        }
        if alive == false {
            e.processExited = true
            switch r.state {
            case .working, .waiting, .unknown:
                e.state = .unknown
                e.detail = "Claude process exited without ending the session"
            case .complete, .error, .idle:
                e.ended = true
                e.state = .idle
                e.detail = "Session ended (process exited)"
            }
            return e
        }
        if r.state == .working {
            let reference = max(r.lastEventAt, lastWake ?? 0)
            let silence = now - reference
            let limit = r.inFlightTools.isEmpty ? policy.staleAfterNoToolSeconds : policy.staleAfterToolSeconds
            if silence > limit {
                e.state = .unknown
                e.stale = true
                e.detail = "No activity for \(Format.duration(silence)) (possibly interrupted)"
            }
        }
        return e
    }

    static func baseDetail(_ r: SessionRecord) -> String {
        switch r.state {
        case .working:
            var s = r.reason == .continued ? "Continuing" : (r.inFlightTools.isEmpty ? "Thinking" : "Running tool")
            if r.activeSubagents > 0 { s += " · \(r.activeSubagents) subagent\(r.activeSubagents == 1 ? "" : "s")" }
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
            if let bg = r.backgroundTasks, bg > 0 { return "Ready · \(bg) background task\(bg == 1 ? "" : "s")" }
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

    /// Aggregate precedence: Waiting > Error > Working > Unknown > Complete > Idle.
    public static func aggregate(_ sessions: [EffectiveSession]) -> SessionState {
        sessions.filter { !$0.ended }.map(\.state).min(by: { $0.precedence < $1.precedence }) ?? .idle
    }

    public struct Counts: Equatable, Sendable {
        public var working = 0, waiting = 0, error = 0, complete = 0, unknown = 0, idle = 0
        public init() {}
        public var active: Int { working + waiting }
    }

    public static func counts(_ sessions: [EffectiveSession]) -> Counts {
        var c = Counts()
        for s in sessions where !s.ended {
            switch s.state {
            case .working: c.working += 1
            case .waiting: c.waiting += 1
            case .error: c.error += 1
            case .complete: c.complete += 1
            case .unknown: c.unknown += 1
            case .idle: c.idle += 1
            }
        }
        return c
    }

    /// Sort: attention first, then working, then most recent activity.
    public static func sorted(_ sessions: [EffectiveSession]) -> [EffectiveSession] {
        sessions.sorted {
            let a = $0.ended ? 9 : $0.state.precedence, b = $1.ended ? 9 : $1.state.precedence
            if a != b { return a < b }
            return $0.record.lastEventAt > $1.record.lastEventAt
        }
    }

    /// Sessions eligible for removal by retention cleanup or "Clear finished".
    /// Active (Working/Waiting) sessions are never eligible.
    public static func isRemovable(_ s: EffectiveSession, now: Double, retention: Double?) -> Bool {
        if s.state.isActive { return false }
        if s.state == .unknown && !s.processExited && !s.stale && !s.ended { return false }
        guard let retention else { return true }   // explicit clear
        return now - s.record.lastEventAt > retention
    }

    public static func timeText(_ s: EffectiveSession, now: Double) -> String {
        let r = s.record
        switch s.state {
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

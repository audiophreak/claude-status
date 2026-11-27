import Foundation

/// Context gathered by the hook process (not from the payload) for a session record.
public struct HookContext: Equatable, Sendable {
    public var client: ClientType
    public var entrypoint: String?
    public var projectDir: String?
    public var pid: Int32?
    public var pidStartTime: Double?

    public init(client: ClientType = .unknown, entrypoint: String? = nil, projectDir: String? = nil,
                pid: Int32? = nil, pidStartTime: Double? = nil) {
        self.client = client; self.entrypoint = entrypoint; self.projectDir = projectDir
        self.pid = pid; self.pidStartTime = pidStartTime
    }
}

/// Deterministic reducer: (previous record, event) -> next record.
///
/// Design rules (see docs/ARCHITECTURE.md):
/// * The persisted `state` is the *foreground* turn state. Background work is a separate
///   dimension (`background`, `schedules`) taken from the documented `background_tasks` and
///   `session_crons` arrays of `Stop` / `SubagentStop`; `Presentation` combines the two.
/// * `Stop` from the main thread completes the foreground turn only; it never implies that
///   background work has finished. `Stop`/`SubagentStop` carrying an `agent_id` never
///   completes the parent session.
/// * Activity after `Stop` from the main thread means a Stop hook blocked and Claude continued.
/// * Events older than the last applied event are ignored (out-of-order protection).
/// * Repeating an event is idempotent with respect to state.
public enum StateMachine {
    /// Tools that block on the user rather than on execution.
    /// Maximum age difference treated as a concurrency reordering (seconds).
    public static let reorderWindow: Double = 120

    static let questionTools: Set<String> = ["AskUserQuestion"]
    static let planTools: Set<String> = ["ExitPlanMode"]

    public static func reduce(_ previous: SessionRecord?, _ e: HookEvent,
                              context: HookContext = HookContext(),
                              projectInfo: ((String) -> ProjectInfo?)? = nil) -> SessionRecord {
        var r: SessionRecord
        if let p = previous {
            r = p
            // Concurrent hook processes can acquire the store lock in a different order
            // than they started; such reorderings span milliseconds to seconds. A much
            // larger gap means the wall clock moved backwards, so the event is accepted
            // rather than freezing the session until the clock catches up.
            let lag = p.lastEventAt - e.timestamp
            if lag > 0 && lag <= StateMachine.reorderWindow {
                r.ignoredOutOfOrder += 1
                return r
            }
        } else {
            r = SessionRecord(sessionId: e.sessionId, timestamp: e.timestamp)
            r.observedMidSession = e.name != .sessionStart
        }

        // Bookkeeping common to every event.
        r.eventCount += 1
        r.lastEventAt = e.timestamp
        r.lastEventName = e.rawName
        if context.client != .unknown { r.client = context.client }
        if let ep = context.entrypoint { r.entrypoint = ep }
        if let pid = context.pid {
            r.pid = pid
            r.pidStartTime = context.pidStartTime
        }
        if let pd = context.projectDir { r.projectDir = pd }
        if let cwd = e.cwd, cwd != r.cwd || r.projectName == nil {
            r.cwd = cwd
            if let info = projectInfo?(cwd) {
                r.gitRepoName = info.repoName
                r.worktreeName = info.worktreeName
            }
            r.projectName = r.displayName
        }

        guard let name = e.name else { return r }   // unregistered event: activity only

        // Any event shows a session hidden by "Clear Finished" again.
        r.dismissed = nil

        // Any event other than SessionEnd proves the session is alive again (e.g. resume).
        if r.ended && name != .sessionEnd {
            r.ended = false
            r.endReason = nil
        }

        switch name {
        case .sessionStart:
            if e.source == "compact" {
                break   // compaction can happen mid-turn; state unchanged
            }
            if !r.state.isActive || e.source == "clear" || e.source == "startup" {
                r.state = .idle
                r.reason = e.source == "resume" ? .resumed : .started
                r.errorCategory = nil
                r.inFlightTools = []
                r.turnStartedAt = nil
            }
            if e.source == "startup" || e.source == "resume" {
                // A new Claude Code process: background work of a previous process is gone.
                clearBackground(&r, known: false)
            }

        case .userPromptSubmit:
            // Claude Code also fires UserPromptSubmit for turns it starts on its own (after a
            // background task exits, a wakeup fires or a background subagent reports). The
            // payload does not say which; a new turn while such work was pending is shown as
            // Continuing (the detail says it may also be a new prompt).
            let pending = (r.state == .complete || r.state == .idle) && continuationPending(r)
            beginTurn(&r, at: e.timestamp, exact: true)
            if pending { r.reason = .autoContinued }

        case .preToolUse:
            if let id = e.toolUseId {
                addInFlight(&r, id, name: e.toolName)
                // A new tool call in the same thread means an earlier permission request of
                // that thread was answered (Claude Code asks for tool calls one at a time).
                if resolvePermissions(&r, scope: scope(e), except: id) { resumeIfAnswered(&r, at: e.timestamp) }
            }
            if let tool = e.toolName, questionTools.contains(tool) {
                if let id = e.toolUseId { markAwaiting(&r, scope(e), id) }
                setWaiting(&r, .question, at: e.timestamp)
            } else if let tool = e.toolName, planTools.contains(tool), e.agentId == nil {
                if let id = e.toolUseId { markAwaiting(&r, scope(e), id) }
                setWaiting(&r, .planApproval, at: e.timestamp)
            } else {
                activity(&r, e)
            }

        case .postToolUse:
            if toolFinished(&r, e) { resumeIfAnswered(&r, at: e.timestamp) }
            activity(&r, e)

        case .postToolUseFailure:
            if toolFinished(&r, e) { resumeIfAnswered(&r, at: e.timestamp) }
            if e.isInterrupt && e.agentId == nil {
                // An aborted tool call: a user cancellation, not an execution error. The
                // turn is treated as ended; any later main-thread event resumes it.
                endTurn(&r, at: e.timestamp)
                r.state = .idle
                r.reason = .interrupted
                r.errorCategory = nil
            } else {
                activity(&r, e)   // ordinary tool error: the turn continues
            }

        case .permissionRequest:
            // AskUserQuestion / ExitPlanMode also pass through the permission flow; they stay
            // a question / plan approval rather than becoming "Approval required".
            let tool = e.toolName ?? ""
            let sc = scope(e)
            if let id = r.inFlightTools.last(where: { r.inFlightToolNames?[$0] == tool && !isAwaiting(r, sc, $0) }) {
                markAwaiting(&r, sc, id)
            } else if !(questionTools.contains(tool) || planTools.contains(tool)) || !hasAwaiting(r, sc) {
                markAwaiting(&r, sc, "?")
            }
            if questionTools.contains(tool) {
                setWaiting(&r, .question, at: e.timestamp)
            } else if planTools.contains(tool) && e.agentId == nil {
                setWaiting(&r, .planApproval, at: e.timestamp)
            } else if !(r.state == .waiting && (r.reason == .question || r.reason == .planApproval)) {
                setWaiting(&r, .permission, at: e.timestamp)
            }

        case .notification:
            switch e.notificationType ?? "" {
            case "permission_prompt":
                // Sent about six seconds after an unanswered permission request (also for
                // AskUserQuestion, which uses the permission flow).
                if !(r.state == .waiting && (r.reason == .question || r.reason == .planApproval)) {
                    setWaiting(&r, .permission, at: e.timestamp)
                }
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                setWaiting(&r, .elicitation, at: e.timestamp)
            case "elicitation_complete", "elicitation_response":
                if r.state == .waiting { resumeWorking(&r, at: e.timestamp) }
            case "idle_prompt":
                // Claude is idle at its input prompt. After a Stop this is just "ready" (keep
                // Complete); if a turn still looked active, it ended without a Stop event.
                if r.state == .working || r.state == .unknown || r.state == .waiting {
                    endTurn(&r, at: e.timestamp)
                    r.state = .idle
                    r.reason = .idleInput
                }
            default:
                break
            }

        case .stop:
            if e.agentId != nil {
                activity(&r, e)   // subagent/teammate stop never completes the parent
            } else {
                applyBackgroundReport(&r, e)
                if e.backgroundTasks == nil {
                    // Not reported: background work is unknown, never assumed finished.
                    r.background = nil
                    r.backgroundTasks = nil
                    r.backgroundReportedAt = nil
                }
                if e.schedules == nil { r.schedules = nil }
                endTurn(&r, at: e.timestamp)
                r.state = .complete
                r.reason = nil
                r.errorCategory = nil
                r.lastCompletedAt = e.timestamp
            }

        case .stopFailure:
            if e.agentId != nil {
                activity(&r, e)
            } else {
                endTurn(&r, at: e.timestamp)
                r.state = .error
                r.reason = .apiError
                r.errorCategory = e.errorCategory ?? "unknown"
            }

        case .subagentStart:
            r.activeSubagents = min(r.activeSubagents + 1, 256)

        case .subagentStop:
            if e.isInternalAgent {
                // Internal agents (prompt suggestions, /btw) have no SubagentStart. Observed in
                // Desktop: after the user stops a turn (no Stop or PostToolUseFailure fires),
                // the prompt-suggestion agent's SubagentStop is the only event. A turn that
                // still looks active may therefore have been interrupted: Unknown, never
                // Complete. Any later main-thread event resumes it (e.g. after /btw).
                if r.state == .working || r.state == .waiting {
                    r.state = .unknown
                    r.reason = .interrupted
                    r.inFlightToolNames = nil
                    r.awaitingPermission = nil
                }
            } else {
                r.activeSubagents = max(r.activeSubagents - 1, 0)
            }
            // SubagentStop carries the parent session's background_tasks / session_crons.
            applyBackgroundReport(&r, e)

        case .sessionEnd:
            r.ended = true
            r.endReason = e.reason
            r.inFlightTools = []
            r.activeSubagents = 0
            clearBackground(&r, known: true)
            if r.turnStartedAt != nil { endTurn(&r, at: e.timestamp) }
            r.state = .idle
            r.reason = .ended
        }
        return r
    }

    // MARK: - Helpers

    static func beginTurn(_ r: inout SessionRecord, at t: Double, exact: Bool) {
        r.state = .working
        r.reason = exact ? nil : .observedMidTurn
        r.errorCategory = nil
        r.turnStartedAt = t
        r.turnObservedFromStart = exact
        r.turnSeq += 1
        r.inFlightTools = []
        r.inFlightToolNames = nil
        r.awaitingPermission = nil
        // Background work started in earlier turns may still be running; it is re-reported
        // at the end of this turn, so the last report is kept.
    }

    static func applyBackgroundReport(_ r: inout SessionRecord, _ e: HookEvent) {
        if let tasks = e.backgroundTasks {
            let active = tasks.filter(\.isActive)
            r.background = active
            r.backgroundTasks = active.count
            r.backgroundReportedAt = e.timestamp
        }
        if let sc = e.schedules { r.schedules = sc }
    }

    static func clearBackground(_ r: inout SessionRecord, known: Bool) {
        r.background = known ? [] : nil
        r.backgroundTasks = known ? 0 : nil
        r.backgroundReportedAt = known ? r.lastEventAt : nil
        r.schedules = known ? ScheduleCounts() : nil
    }

    /// Background work or a one-shot wakeup was pending at the last report.
    static func continuationPending(_ r: SessionRecord) -> Bool {
        (r.activeBackground?.isEmpty == false) || (r.schedules?.oneShot ?? 0) > 0
    }

    static func endTurn(_ r: inout SessionRecord, at t: Double) {
        if let start = r.turnStartedAt {
            r.lastTurnDuration = max(0, t - start)
            r.lastTurnDurationExact = r.turnObservedFromStart
        }
        r.turnStartedAt = nil
        r.inFlightTools = []
        r.inFlightToolNames = nil
        r.awaitingPermission = nil
    }

    static func addInFlight(_ r: inout SessionRecord, _ id: String, name: String? = nil) {
        if !r.inFlightTools.contains(id) { r.inFlightTools.append(id) }
        if r.inFlightTools.count > SessionRecord.maxInFlightTools {
            let drop = r.inFlightTools.prefix(r.inFlightTools.count - SessionRecord.maxInFlightTools)
            r.inFlightTools.removeFirst(drop.count)
            for d in drop { r.inFlightToolNames?[d] = nil }
        }
        if let name {
            var names = r.inFlightToolNames ?? [:]
            names[id] = name
            r.inFlightToolNames = names
        }
    }

    /// Permission bookkeeping is per thread: the main thread or one subagent (`agent_id`).
    static func scope(_ e: HookEvent) -> String { e.agentId ?? "main" }

    static func markAwaiting(_ r: inout SessionRecord, _ scope: String, _ id: String) {
        let key = "\(scope)|\(id)"
        var a = r.awaitingPermission ?? []
        if !a.contains(key) { a.append(key) }
        r.awaitingPermission = Array(a.suffix(SessionRecord.maxInFlightTools))
    }

    static func isAwaiting(_ r: SessionRecord, _ scope: String, _ id: String) -> Bool {
        r.awaitingPermission?.contains("\(scope)|\(id)") ?? false
    }

    static func hasAwaiting(_ r: SessionRecord, _ scope: String) -> Bool {
        r.awaitingPermission?.contains { $0.hasPrefix(scope + "|") } ?? false
    }

    /// Drop the thread's unanswered requests other than `except` (answered: Claude moved on).
    @discardableResult
    static func resolvePermissions(_ r: inout SessionRecord, scope: String, except id: String) -> Bool {
        guard var a = r.awaitingPermission else { return false }
        let before = a.count
        a.removeAll { $0.hasPrefix(scope + "|") && $0 != "\(scope)|\(id)" }
        r.awaitingPermission = a.isEmpty ? nil : a
        return a.count != before
    }

    /// The last open request was answered: Claude is working again.
    static func resumeIfAnswered(_ r: inout SessionRecord, at t: Double) {
        if r.state == .waiting, (r.awaitingPermission ?? []).isEmpty { resumeWorking(&r, at: t) }
    }

    /// Returns true when an open permission request was resolved by this event.
    @discardableResult
    static func toolFinished(_ r: inout SessionRecord, _ e: HookEvent) -> Bool {
        let before = r.awaitingPermission?.count ?? 0
        let sc = scope(e)
        if let id = e.toolUseId {
            r.inFlightTools.removeAll { $0 == id }
            r.inFlightToolNames?[id] = nil
            if r.inFlightToolNames?.isEmpty == true { r.inFlightToolNames = nil }
            r.awaitingPermission?.removeAll { $0.hasSuffix("|" + id) }
        }
        // An unmatched request in this thread is answered once any of its tools finishes.
        r.awaitingPermission?.removeAll { $0 == "\(sc)|?" }
        if r.awaitingPermission?.isEmpty == true { r.awaitingPermission = nil }
        return (r.awaitingPermission?.count ?? 0) != before
    }

    static func setWaiting(_ r: inout SessionRecord, _ reason: StateReason, at t: Double) {
        if r.turnStartedAt == nil {
            r.turnStartedAt = t
            r.turnObservedFromStart = false
            r.turnSeq += 1
        }
        r.state = .waiting
        r.reason = reason
        r.errorCategory = nil
    }

    static func resumeWorking(_ r: inout SessionRecord, at t: Double) {
        if r.turnStartedAt == nil {
            r.turnStartedAt = t
            r.turnObservedFromStart = false
            r.turnSeq += 1
        }
        r.state = .working
        r.reason = nil
        r.errorCategory = nil
    }

    /// Tool / subagent activity.
    static func activity(_ r: inout SessionRecord, _ e: HookEvent) {
        switch r.state {
        case .working:
            break
        case .waiting:
            // The user answered once no tracked request is open. Without a tracked request
            // (e.g. a notification-only prompt), a main-thread tool event means they responded;
            // background subagent activity does not.
            if let a = r.awaitingPermission, !a.isEmpty { break }
            if e.agentId == nil {
                resumeWorking(&r, at: e.timestamp)
            } else {
                r.backgroundActivityAt = e.timestamp
            }
        case .complete:
            // Background subagents may keep emitting events after the main turn finished;
            // that does not reopen the main turn, it is evidence of background work. Main-
            // thread activity after Stop means Claude continued (Stop hook or background
            // task / wakeup notification).
            if e.agentId == nil {
                let auto = continuationPending(r)
                resumeWorking(&r, at: e.timestamp)
                r.reason = auto ? .autoContinued : .continued
            } else {
                r.backgroundActivityAt = e.timestamp
            }
        case .idle, .error:
            if e.agentId == nil {
                resumeWorking(&r, at: e.timestamp)
                r.reason = .observedMidTurn
            } else {
                r.backgroundActivityAt = e.timestamp
            }
        case .unknown:
            resumeWorking(&r, at: e.timestamp)
            r.reason = .observedMidTurn
        }
    }
}

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
/// * `Stop` from the main thread completes a turn; `Stop`/`SubagentStop` carrying an `agent_id`
///   never completes the parent session.
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

        case .userPromptSubmit:
            beginTurn(&r, at: e.timestamp, exact: true)

        case .preToolUse:
            if let id = e.toolUseId { addInFlight(&r, id) }
            if let tool = e.toolName, questionTools.contains(tool) {
                setWaiting(&r, .question, at: e.timestamp)
            } else if let tool = e.toolName, planTools.contains(tool), e.agentId == nil {
                setWaiting(&r, .planApproval, at: e.timestamp)
            } else {
                activity(&r, e)
            }

        case .postToolUse:
            if let id = e.toolUseId { r.inFlightTools.removeAll { $0 == id } }
            activity(&r, e)

        case .postToolUseFailure:
            if let id = e.toolUseId { r.inFlightTools.removeAll { $0 == id } }
            if e.isInterrupt && e.agentId == nil {
                endTurn(&r, at: e.timestamp)
                r.state = .error
                r.reason = .interrupted
            } else {
                activity(&r, e)   // ordinary tool error: the turn continues
            }

        case .permissionRequest:
            setWaiting(&r, .permission, at: e.timestamp)

        case .notification:
            switch e.notificationType ?? "" {
            case "permission_prompt":
                setWaiting(&r, .permission, at: e.timestamp)
            case "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input":
                setWaiting(&r, .elicitation, at: e.timestamp)
            case "elicitation_complete", "elicitation_response":
                if r.state == .waiting { resumeWorking(&r, at: e.timestamp) }
            case "idle_prompt":
                // Claude is waiting for input. After a Stop this is just "ready" (keep Complete);
                // if a turn still looked active, the turn ended without a Stop (e.g. interrupt).
                if r.state == .working || r.state == .unknown {
                    endTurn(&r, at: e.timestamp)
                    r.state = .waiting
                    r.reason = .idleInput
                }
            default:
                break
            }

        case .stop:
            if e.agentId != nil {
                activity(&r, e)   // subagent/teammate stop never completes the parent
            } else {
                r.backgroundTasks = e.backgroundTaskCount
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
            r.activeSubagents = max(r.activeSubagents - 1, 0)

        case .sessionEnd:
            r.ended = true
            r.endReason = e.reason
            r.inFlightTools = []
            r.activeSubagents = 0
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
        r.backgroundTasks = nil
    }

    static func endTurn(_ r: inout SessionRecord, at t: Double) {
        if let start = r.turnStartedAt {
            r.lastTurnDuration = max(0, t - start)
            r.lastTurnDurationExact = r.turnObservedFromStart
        }
        r.turnStartedAt = nil
        r.inFlightTools = []
    }

    static func addInFlight(_ r: inout SessionRecord, _ id: String) {
        if !r.inFlightTools.contains(id) { r.inFlightTools.append(id) }
        if r.inFlightTools.count > SessionRecord.maxInFlightTools {
            r.inFlightTools.removeFirst(r.inFlightTools.count - SessionRecord.maxInFlightTools)
        }
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
            // A tool event after a permission prompt or question means the user responded.
            resumeWorking(&r, at: e.timestamp)
        case .complete:
            // Background subagents may keep emitting events after the main turn finished;
            // that does not reopen the main turn. Main-thread activity after Stop means a
            // Stop hook blocked the stop and Claude continued.
            if e.agentId == nil {
                resumeWorking(&r, at: e.timestamp)
                r.reason = .continued
            }
        case .idle, .unknown, .error:
            if e.agentId == nil || r.state != .error {
                resumeWorking(&r, at: e.timestamp)
                r.reason = .observedMidTurn
            }
        }
    }
}

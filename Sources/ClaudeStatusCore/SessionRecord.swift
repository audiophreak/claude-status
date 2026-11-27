import Foundation

/// Session states shown to the user. Raw values are persisted.
public enum SessionState: String, Codable, CaseIterable, Sendable {
    case working
    case complete
    case waiting
    case error
    case idle
    case unknown

    /// Aggregate precedence (lower = higher priority): Waiting, Error, Working, Unknown, Complete, Idle.
    public var precedence: Int {
        switch self {
        case .waiting: return 0
        case .error: return 1
        case .working: return 2
        case .unknown: return 3
        case .complete: return 4
        case .idle: return 5
        }
    }

    public var label: String {
        switch self {
        case .working: return "Working"
        case .complete: return "Complete"
        case .waiting: return "Waiting"
        case .error: return "Error"
        case .idle: return "Idle"
        case .unknown: return "Unknown"
        }
    }

    /// Active sessions are never removed by "Clear finished".
    public var isActive: Bool { self == .working || self == .waiting }
}

/// Why a session is in its current state. Persisted raw values.
public enum StateReason: String, Codable, Sendable {
    case started            // SessionStart seen, no prompt yet
    case resumed
    case permission         // PermissionRequest / permission_prompt notification
    case question           // AskUserQuestion tool
    case planApproval       // ExitPlanMode tool
    case elicitation        // MCP elicitation dialog / agent needs input
    case idleInput          // idle_prompt while a turn appeared to be running
    case interrupted        // PostToolUseFailure is_interrupt
    case apiError           // StopFailure
    case ended              // SessionEnd
    case observedMidTurn    // first event seen was mid-turn activity
    case continued          // activity after Stop (stop hook continuation)
    case autoContinued      // activity after Stop while background work / a wakeup was pending
}

public enum ClientType: String, Codable, Sendable {
    case desktop
    case cli
    case unknown

    public var label: String {
        switch self {
        case .desktop: return "Desktop"
        case .cli: return "CLI"
        case .unknown: return "Unknown client"
        }
    }
}

/// Persisted per-session record. Contains no prompt, transcript, tool input or output.
public struct SessionRecord: Codable, Equatable, Sendable {
    public static let schema = 1
    public static let maxInFlightTools = 64

    public var schemaVersion: Int = SessionRecord.schema
    public var sessionId: String
    public var state: SessionState
    public var reason: StateReason?
    public var errorCategory: String?

    public var cwd: String?
    public var projectDir: String?
    public var projectName: String?
    public var gitRepoName: String?
    public var worktreeName: String?
    public var client: ClientType
    public var entrypoint: String?
    public var pid: Int32?
    public var pidStartTime: Double?

    public var firstSeenAt: Double
    public var lastEventAt: Double
    public var lastEventName: String
    public var turnStartedAt: Double?
    public var turnObservedFromStart: Bool
    public var lastTurnDuration: Double?
    public var lastTurnDurationExact: Bool
    public var lastCompletedAt: Double?
    public var turnSeq: Int

    public var inFlightTools: [String]
    public var activeSubagents: Int
    /// Number of in-flight background tasks at the last report (kept for compatibility).
    public var backgroundTasks: Int?
    /// In-flight background tasks from the most recent documented `background_tasks` report.
    /// nil = Claude Code has not reported background work for this session (unknown).
    public var background: [BackgroundTaskInfo]?
    /// When `background` was last reported.
    public var backgroundReportedAt: Double?
    /// Last time a subagent hook event (documented `agent_id`) arrived while the foreground
    /// turn was not running: direct evidence that background subagent work is in progress.
    public var backgroundActivityAt: Double?
    /// Tool calls (by `tool_use_id`) for which a permission decision was requested and not yet
    /// resolved. `"?"` stands for a request that could not be matched to a tool call.
    public var awaitingPermission: [String]?
    /// Tool names of in-flight tool calls, keyed by `tool_use_id` (names only, never input).
    public var inFlightToolNames: [String: String]?
    /// Session-scoped scheduled wakeups at the last report. nil = not reported.
    public var schedules: ScheduleCounts?
    /// Hidden by "Clear Finished" while its Claude process is still running. Any new event
    /// shows the session again. Keeping the record keeps the process correlated (observed).
    public var dismissed: Bool?
    public var ended: Bool
    public var endReason: String?
    public var observedMidSession: Bool
    public var eventCount: Int
    public var ignoredOutOfOrder: Int

    public init(sessionId: String, timestamp: Double) {
        self.sessionId = sessionId
        self.state = .unknown
        self.client = .unknown
        self.firstSeenAt = timestamp
        self.lastEventAt = timestamp
        self.lastEventName = ""
        self.turnObservedFromStart = false
        self.lastTurnDurationExact = false
        self.turnSeq = 0
        self.inFlightTools = []
        self.activeSubagents = 0
        self.ended = false
        self.observedMidSession = true
        self.eventCount = 0
        self.ignoredOutOfOrder = 0
    }

    /// Active background tasks, or nil when background work has not been reported.
    public var activeBackground: [BackgroundTaskInfo]? { background?.filter(\.isActive) }

    /// Display name: git repository name, otherwise the project folder name.
    public var displayName: String {
        if let r = gitRepoName, !r.isEmpty { return r }
        if let p = projectDir ?? cwd { return (p as NSString).lastPathComponent }
        return "Session \(sessionId.prefix(8))"
    }
}

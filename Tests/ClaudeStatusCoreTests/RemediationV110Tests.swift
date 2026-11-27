import XCTest
@testable import ClaudeStatusCore

/// v1.1.0 remediation: permission/question tracking, interrupts, background-report
/// provenance, background subagent evidence, scheduled continuation times, sleep/wake,
/// discovery, storage bounds and sanitized diagnostics. Event sequences marked "observed"
/// were recorded live from Claude Code Desktop 2.1.330 / CLI 2.1.325 (structure only).
final class RemediationV110Tests: TempDirTestCase {
    let shellA = BackgroundTaskInfo(id: "task-a", type: "shell", status: "running")
    let sub = BackgroundTaskInfo(id: "task-s", type: "subagent", status: "running")

    func bgStop(_ t: Double, _ bg: [BackgroundTaskInfo], crons: ScheduleCounts = ScheduleCounts(), agent: String? = nil,
                name: HookEventName = .stop, agentType: String? = nil) -> HookEvent {
        var e = ev(name, t: t, agent: agent)
        e.backgroundTasks = bg
        e.schedules = crons
        if let agentType { e.agentType = agentType.isEmpty ? nil : agentType; e.isInternalAgent = agent != nil && agentType.isEmpty }
        return e
    }

    func view(_ r: SessionRecord, now: Double? = nil, alive: Bool? = true, wake: Double? = nil) -> EffectiveSession {
        Presentation.evaluate(r, now: now ?? r.lastEventAt + 1, alive: alive, lastWake: wake)
    }

    let start = [ev(.sessionStart, t: 0, source: "startup")]

    // MARK: Permission and user-input requests

    func testAskUserQuestionStaysAQuestionThroughThePermissionFlow() {
        // Observed (CLI): PreToolUse AskUserQuestion -> PermissionRequest AskUserQuestion ->
        // Notification permission_prompt -> (answer) PostToolUse AskUserQuestion.
        var r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "AskUserQuestion", toolUseId: "q"),
                               ev(.permissionRequest, t: 2.1, tool: "AskUserQuestion"),
                               ev(.notification, t: 8, notification: "permission_prompt")])
        XCTAssertEqual(r.state, .waiting)
        XCTAssertEqual(r.reason, .question, "must not become 'Approval required'")
        XCTAssertEqual(view(r).detail, "Question for you")
        r = apply([ev(.postToolUse, t: 10, tool: "AskUserQuestion", toolUseId: "q")], from: r)
        XCTAssertEqual(r.state, .working)
        XCTAssertNil(r.awaitingPermission)
    }

    func testMultipleSimultaneousApprovalsWaitUntilAllAreAnswered() {
        var r = apply(start + [ev(.userPromptSubmit, t: 1),
                               ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"), ev(.permissionRequest, t: 2.1, tool: "Bash"),
                               ev(.preToolUse, t: 3, agent: "sub1", tool: "Write", toolUseId: "b"),
                               ev(.permissionRequest, t: 3.1, agent: "sub1", tool: "Write")])
        XCTAssertEqual(r.awaitingPermission?.count, 2)
        r = apply([ev(.postToolUse, t: 5, tool: "Bash", toolUseId: "a")], from: r)
        XCTAssertEqual(r.state, .waiting, "the subagent's request is still open")
        r = apply([ev(.postToolUse, t: 6, agent: "sub1", tool: "Write", toolUseId: "b")], from: r)
        XCTAssertEqual(r.state, .working, "both answered (a subagent tool finishing resolves its own request)")
    }

    func testParallelToolFinishingDoesNotEndWaiting() {
        // A tool that needed no approval finishing while another tool's prompt is open.
        var r = apply(start + [ev(.userPromptSubmit, t: 1),
                               ev(.preToolUse, t: 2, tool: "Read", toolUseId: "r"),
                               ev(.preToolUse, t: 2.1, tool: "Bash", toolUseId: "a"), ev(.permissionRequest, t: 2.2, tool: "Bash")])
        r = apply([ev(.postToolUse, t: 3, tool: "Read", toolUseId: "r")], from: r)
        XCTAssertEqual(r.state, .waiting)
        XCTAssertEqual(r.reason, .permission)
    }

    func testBackgroundSubagentActivityDoesNotAnswerAMainThreadPrompt() {
        var r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"),
                               ev(.permissionRequest, t: 2.1, tool: "Bash")])
        r = apply([ev(.preToolUse, t: 5, agent: "bgsub", tool: "Grep", toolUseId: "g"),
                   ev(.postToolUse, t: 6, agent: "bgsub", tool: "Grep", toolUseId: "g")], from: r)
        XCTAssertEqual(r.state, .waiting)
    }

    func testApprovalGrantedResumesWorking() {
        // Observed (Desktop and CLI): PermissionRequest -> permission_prompt -> PostToolUse.
        let r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"),
                               ev(.permissionRequest, t: 2.1, tool: "Bash"), ev(.notification, t: 8, notification: "permission_prompt"),
                               ev(.postToolUse, t: 20, tool: "Bash", toolUseId: "a")])
        XCTAssertEqual(r.state, .working)
        XCTAssertNil(r.awaitingPermission)
    }

    func testDeniedRequestResolvedWhenClaudeMovesOn() {
        // Denial without interrupt: no PostToolUse for the denied call; the next tool call in
        // the same thread means the request was answered.
        let r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"),
                               ev(.permissionRequest, t: 2.1, tool: "Bash"), ev(.preToolUse, t: 9, tool: "Read", toolUseId: "b")])
        XCTAssertEqual(r.state, .working)
        XCTAssertNil(r.awaitingPermission)
        let done = apply([ev(.stop, t: 12)], from: apply(start + [ev(.userPromptSubmit, t: 1),
                                                                    ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"),
                                                                    ev(.permissionRequest, t: 2.1, tool: "Bash")]))
        XCTAssertEqual(done.state, .complete)
        XCTAssertNil(done.awaitingPermission)
    }

    func testDenialWithEscStaysWaitingUntilNextPrompt() {
        // Observed (CLI): declining with Esc emits no event at all. The session is waiting for
        // the user either way; the next prompt resolves it.
        var r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"),
                               ev(.permissionRequest, t: 2.1, tool: "Bash")])
        XCTAssertEqual(view(r, now: 2000).state, .waiting, "never Complete or Idle without evidence")
        r = apply([ev(.userPromptSubmit, t: 2100)], from: r)
        XCTAssertEqual(r.state, .working)
        XCTAssertNil(r.awaitingPermission)
    }

    func testPlanApprovalAndElicitation() {
        let p = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "ExitPlanMode", toolUseId: "p"),
                               ev(.permissionRequest, t: 2.1, tool: "ExitPlanMode")])
        XCTAssertEqual(p.reason, .planApproval)
        let e = apply(start + [ev(.userPromptSubmit, t: 1), ev(.notification, t: 2, notification: "elicitation_dialog")])
        XCTAssertEqual(e.reason, .elicitation)
        XCTAssertEqual(apply([ev(.notification, t: 3, notification: "elicitation_response")], from: e).state, .working)
    }

    func testWaitingWithBackgroundTasksShowsBothDimensions() {
        var r = apply(start + [ev(.userPromptSubmit, t: 1), bgStop(5, [shellA]), ev(.userPromptSubmit, t: 30),
                               ev(.preToolUse, t: 31, tool: "Bash", toolUseId: "a"), ev(.permissionRequest, t: 31.5, tool: "Bash")])
        let v = view(r)
        XCTAssertEqual(v.state, .waiting)
        XCTAssertTrue(v.showsDimensions)
        XCTAssertTrue(v.backgroundSummary.contains("at last report"), v.backgroundSummary)
        r = apply([ev(.postToolUse, t: 40, tool: "Bash", toolUseId: "a"), bgStop(45, [])], from: r)
        XCTAssertEqual(view(r).state, .complete)
    }

    // MARK: Interrupts and cancellation

    func testDesktopStopDuringToolIsPossiblyInterruptedNeverComplete() {
        // Observed (Desktop): UserPromptSubmit, PreToolUse Bash, [Stop pressed], then only the
        // internal prompt-suggestion agent's SubagentStop (empty agent_type), bg=[].
        let r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"),
                               bgStop(14, [], agent: "internal", name: .subagentStop, agentType: "")])
        let v = view(r)
        XCTAssertEqual(v.state, .unknown)
        XCTAssertEqual(v.label, "Unknown — Possibly interrupted")
        XCTAssertNotEqual(v.state, .complete)
        XCTAssertNotEqual(v.state, .error)
        // Next prompt: a normal new turn.
        let n = apply([ev(.userPromptSubmit, t: 30)], from: r)
        XCTAssertEqual(n.state, .working)
        XCTAssertNil(n.reason)
    }

    func testInternalAgentAfterStopChangesNothing() {
        // Observed (both clients): every Stop is followed by an internal SubagentStop.
        let r = apply(start + [ev(.userPromptSubmit, t: 1), bgStop(5, []), bgStop(6, [], agent: "internal", name: .subagentStop, agentType: "")])
        XCTAssertEqual(view(r).state, .complete)
        XCTAssertEqual(r.activeSubagents, 0)
    }

    func testBtwSideQuestionMidTurnSelfCorrects() {
        // /btw also uses an internal agent; the main turn's next event resumes it.
        let r = apply(start + [ev(.userPromptSubmit, t: 1), bgStop(3, [], agent: "internal", name: .subagentStop, agentType: ""),
                               ev(.preToolUse, t: 4, tool: "Read", toolUseId: "r")])
        XCTAssertEqual(r.state, .working)
    }

    func testRealSubagentStopDoesNotSignalInterrupt() {
        let r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.subagentStart, t: 2, agent: "a1"),
                               bgStop(9, [], agent: "a1", name: .subagentStop, agentType: "general-purpose")])
        XCTAssertEqual(r.state, .working)
        XCTAssertEqual(r.activeSubagents, 0)
    }

    func testEscDuringGenerationEmitsNothingAndBecomesUnknownOnlyAfterTheLimit() {
        // Observed (CLI): Esc while generating text fires no hook event (no Stop, no idle_prompt).
        let r = apply(start + [ev(.userPromptSubmit, t: 0)])
        XCTAssertEqual(view(r, now: 60).state, .working)
        XCTAssertEqual(view(r, now: 60).confidence, .confirmed)
        let quiet = view(r, now: 6 * 60)
        XCTAssertEqual(quiet.state, .working)
        XCTAssertEqual(quiet.confidence, .partial, "uncertainty is visible before the limit")
        let stale = view(r, now: 21 * 60)
        XCTAssertEqual(stale.state, .unknown)
        XCTAssertTrue(stale.detail.contains("possibly stopped"))
    }

    func testStoppedDuringBashToolUsesTheBashTimeoutBound() {
        // Observed (Desktop, second run): Stop during a foreground Bash call fired no event at all.
        let r = apply(start + [ev(.userPromptSubmit, t: 0), ev(.preToolUse, t: 1, tool: "Bash", toolUseId: "b")])
        XCTAssertEqual(view(r, now: 9 * 60).confidence, .confirmed)
        let quiet = view(r, now: 12 * 60)
        XCTAssertEqual(quiet.state, .working)
        XCTAssertEqual(quiet.confidence, .partial)
        XCTAssertTrue(quiet.confidenceNote.contains("Bash"))
        XCTAssertEqual(view(r, now: 61 * 60).state, .unknown)
        // Another tool (e.g. MCP) keeps the longer bound.
        let m = apply(start + [ev(.userPromptSubmit, t: 0), ev(.preToolUse, t: 1, tool: "mcp__db__query", toolUseId: "m")])
        XCTAssertEqual(view(m, now: 61 * 60).state, .working)
        XCTAssertEqual(view(m, now: 121 * 60).state, .unknown)
    }

    func testToolAbortIsCancellationAndLaterActivityResumes() {
        var r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, toolUseId: "a"),
                               ev(.postToolUseFailure, t: 5, toolUseId: "a", interrupt: true)])
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(view(r).label, "Idle — Interrupted")
        r = apply([ev(.preToolUse, t: 6, tool: "Read", toolUseId: "b")], from: r)
        XCTAssertEqual(r.state, .working, "Claude continued after the aborted tool")
    }

    func testInterruptedTurnWithBackgroundWorkStaysWorkingBackground() {
        let r = apply(start + [ev(.userPromptSubmit, t: 1), bgStop(3, [shellA]), ev(.userPromptSubmit, t: 10),
                               ev(.preToolUse, t: 11, toolUseId: "a"), ev(.postToolUseFailure, t: 12, toolUseId: "a", interrupt: true)])
        let v = view(r)
        XCTAssertEqual(v.state, .working)
        XCTAssertEqual(v.activity, .background, "background tasks are cancelled independently of the foreground")
    }

    // MARK: Background report provenance and subagents

    func testBackgroundCountIsLabelledAsLastReported() {
        let r = apply(start + [ev(.userPromptSubmit, t: 1), bgStop(10, [shellA, sub])])
        XCTAssertEqual(view(r, now: 11).backgroundSummary, "2 tasks (shell, subagent)")
        XCTAssertEqual(view(r, now: 10 + 300).backgroundSummary, "2 tasks (shell, subagent) · reported 5m ago")
        // Automatic continuation: the report predates the new turn and may be out of date.
        let c = apply([ev(.userPromptSubmit, t: 400)], from: r)
        let v = view(c)
        XCTAssertEqual(v.label, "Working — Continuing")
        XCTAssertTrue(v.backgroundReportPredatesTurn)
        XCTAssertEqual(v.confidence, .partial)
        XCTAssertTrue(v.backgroundSummary.hasSuffix("at last report · updated when this turn ends"), v.backgroundSummary)
    }

    func testBackgroundSubagentEventsAreBackgroundEvidenceNotForeground() {
        var r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.subagentStart, t: 2, agent: "bg1"), bgStop(4, [sub])])
        r = apply([ev(.preToolUse, t: 20, agent: "bg1", tool: "Bash", toolUseId: "x"),
                   ev(.postToolUse, t: 50, agent: "bg1", tool: "Bash", toolUseId: "x")], from: r)
        XCTAssertEqual(r.state, .complete, "subagent activity never reopens the parent's turn")
        XCTAssertEqual(r.backgroundActivityAt, 50)
        let v = view(r, now: 60)
        XCTAssertEqual(v.activity, .background)
        XCTAssertTrue(v.detail.contains("subagent active"), v.detail)
        // Subagent finishes: SubagentStop carries the parent's updated report.
        r = apply([bgStop(70, [], agent: "bg1", name: .subagentStop, agentType: "general-purpose")], from: r)
        XCTAssertEqual(view(r).state, .complete)
        // Parent continues on its own afterwards and finishes.
        r = apply([ev(.userPromptSubmit, t: 72), bgStop(75, [])], from: r)
        XCTAssertEqual(view(r).state, .complete)
        XCTAssertEqual(r.activeSubagents, 0)
    }

    func testSubagentCompletionNeverCompletesTheParent() {
        let r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.subagentStart, t: 2, agent: "a"),
                               bgStop(5, [], agent: "a", name: .subagentStop, agentType: "Explore"),
                               bgStop(6, [], agent: "a", name: .stop)])
        XCTAssertEqual(r.state, .working)
    }

    // MARK: Scheduled continuation

    func testCronNextFireTimes() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let base = Date(timeIntervalSince1970: 1_795_800_000)   // Friday 2026-11-27 17:20:00 UTC
        XCTAssertEqual(CronSchedule("25 17 27 11 *")?.next(after: base, calendar: cal)?.timeIntervalSince1970, 1_795_800_300)
        XCTAssertEqual(CronSchedule("*/15 * * * *")?.next(after: base, calendar: cal)?.timeIntervalSince1970, 1_795_800_600)
        XCTAssertEqual(CronSchedule("0 9 * * 1-5")?.next(after: base, calendar: cal).map { cal.component(.weekday, from: $0) }, 2,
                       "next weekday 09:00 after Friday afternoon is Monday")
        XCTAssertNil(CronSchedule("not a cron"))
        XCTAssertNil(CronSchedule("61 * * * *"))
        XCTAssertNil(CronSchedule("* * * *"))
        XCTAssertNotNil(CronSchedule("0 0 * * 7"), "7 is Sunday")
    }

    func testOneShotWakeupTimeIsParsedFromSessionCronsWithoutThePrompt() throws {
        let t = Date().timeIntervalSince1970
        let due = Date(timeIntervalSince1970: t + 600)
        let c = Calendar.current.dateComponents([.minute, .hour, .day, .month], from: due)
        let expr = "\(c.minute!) \(c.hour!) \(c.day!) \(c.month!) *"
        let e = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "Stop", "background_tasks": [],
                                                "session_crons": [["id": "c1", "schedule": expr, "recurring": false, "prompt": "SECRET-PROMPT"],
                                                                  ["id": "c2", "schedule": "0 9 * * *", "recurring": true, "prompt": "x"]]]),
                                          timestamp: t)
        XCTAssertEqual(e.schedules?.oneShot, 1)
        XCTAssertEqual(e.schedules?.recurring, 1)
        let next = try XCTUnwrap(e.schedules?.nextOneShotAt)
        XCTAssertLessThan(abs(next - (t + 600)), 61)
        var r = apply(start + [ev(.userPromptSubmit, t: t - 5)])
        r = StateMachine.reduce(r, e)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(r), as: UTF8.self).contains("SECRET"))
        let v = view(r, now: t + 1)
        XCTAssertEqual(v.label, "Continuation scheduled")
        XCTAssertEqual(v.activity, .scheduled)
        XCTAssertTrue(v.detail.contains("continues at \(Format.timeOfDay(next))"), v.detail)
        XCTAssertEqual(Presentation.counts([v]).executing, 0, "a scheduled wakeup is not active execution")
        XCTAssertEqual(Presentation.summary(Presentation.counts([v])), "1 scheduled")
        // Overdue without any event: flagged, not silently Working.
        let late = view(r, now: next + 900)
        XCTAssertEqual(late.confidence, .partial)
        XCTAssertTrue(late.detail.contains("was due"), late.detail)
        // The wakeup fires: Claude continues on its own.
        let woke = apply([ev(.userPromptSubmit, t: next + 1)], from: r)
        XCTAssertEqual(view(woke).label, "Working — Continuing")
    }

    func testScheduledAndBackgroundOverlap() {
        let r = apply(start + [ev(.userPromptSubmit, t: 1), bgStop(5, [shellA], crons: ScheduleCounts(oneShot: 1, recurring: 0, nextOneShotAt: 900))])
        let v = view(r, now: 10)
        XCTAssertEqual(v.activity, .background, "running work takes precedence over a pending wakeup")
        XCTAssertTrue(v.backgroundSummary.contains("1 wakeup scheduled for"), v.backgroundSummary)
        let cancelled = apply([ev(.userPromptSubmit, t: 20), bgStop(25, [], crons: ScheduleCounts())], from: r)
        XCTAssertEqual(view(cancelled).state, .complete, "cancelled schedule and finished task -> Complete")
    }

    // MARK: Sleep / wake

    func testSleepIsNotSilence() {
        let r = apply(start + [ev(.userPromptSubmit, t: 0), ev(.preToolUse, t: 1, toolUseId: "a")])
        // 10 h later, but the Mac woke 2 minutes ago: the turn gets a fresh grace period.
        let now = 10.0 * 3600
        XCTAssertEqual(view(r, now: now, wake: nil).state, .unknown)
        let v = view(r, now: now, wake: now - 120)
        XCTAssertEqual(v.state, .working)
        XCTAssertEqual(v.silence, 120)
        XCTAssertNotNil(SystemClock.bootTime())
        if let w = SystemClock.lastWake() { XCTAssertGreaterThanOrEqual(w, SystemClock.bootTime()!) }
    }

    // MARK: Discovery and correlation

    func testConcurrentSessionsInTheSameDirectoryAreDistinct() {
        var a = apply([ev(.sessionStart, "sa", t: 10, source: "startup", cwd: "/w")]); a.pid = 100; a.pidStartTime = 5
        var b = apply([ev(.sessionStart, "sb", t: 20, source: "startup", cwd: "/w")]); b.pid = 200; b.pidStartTime = 15
        let procs = [DetectedProcess(pid: 100, startTime: 5, client: .cli, cwd: "/w"),
                     DetectedProcess(pid: 200, startTime: 15, client: .desktop, cwd: "/w"),
                     DetectedProcess(pid: 300, startTime: 25, client: .cli, cwd: "/w")]
        let un = Presentation.unobservedProcesses(procs, records: [a, b])
        XCTAssertEqual(un.map(\.pid), [300], "a third process in the same folder is its own unobserved session")
    }

    func testPidReuseNeverMatchesAndPidlessRecordsNeedAPlausibleProcess() {
        var r = apply([ev(.userPromptSubmit, "sx", t: 100, cwd: "/w")]); r.pid = 100; r.pidStartTime = 50
        let reused = DetectedProcess(pid: 100, startTime: 500, client: .cli, cwd: "/w")
        XCTAssertEqual(Presentation.unobservedProcesses([reused], records: [r]).count, 1)
        XCTAssertFalse(ProcessInspector.isAlive(pid: getpid(), startTime: 1))
        // A record without a PID only accounts for a process that already ran at its last event.
        let pidless = apply([ev(.userPromptSubmit, "sy", t: 100, cwd: "/w")])
        let older = DetectedProcess(pid: 7, startTime: 90, client: .cli, cwd: "/w")
        let newer = DetectedProcess(pid: 8, startTime: 200, client: .cli, cwd: "/w")
        XCTAssertEqual(Presentation.unobservedProcesses([older, newer], records: [pidless]).map(\.pid), [8])
    }

    func testRestartAndReconciliationKeepState() throws {
        // App restart: records are re-read and re-evaluated; nothing in memory is needed.
        let store = SessionStore(paths: paths)
        var r = apply(start + [ev(.userPromptSubmit, t: 1), bgStop(5, [shellA])])
        r.pid = getpid()
        r.pidStartTime = ProcessInspector.info(getpid())?.startTime
        try store.withLock { try store.save(r) }
        let reloaded = store.loadAll().records
        XCTAssertEqual(reloaded, [r])
        let v = Presentation.evaluate(reloaded[0], now: 100, alive: SessionMaintenance.liveness(reloaded[0]), lastWake: nil)
        XCTAssertEqual(v.label, "Working — Background", "a restart never marks active work Complete")
    }

    // MARK: Cleanup and storage bounds

    func testStorageIsBoundedWithoutTouchingActiveWork() throws {
        let store = SessionStore(paths: paths)
        try store.withLock {
            for i in 0..<30 {
                var r = apply([ev(.userPromptSubmit, "old\(i)", t: Double(i)), ev(.stop, "old\(i)", t: Double(i) + 1)])
                r.background = []
                r.pid = 999_999   // not running
                try store.save(r)
            }
            var active = apply([ev(.userPromptSubmit, "active", t: 0)])
            active.pid = getpid(); active.pidStartTime = ProcessInspector.info(getpid())?.startTime
            try store.save(active)
        }
        let res = SessionMaintenance.cleanup(store: store, now: 60, retention: 3600, maxRecords: 10, alive: SessionMaintenance.liveness)
        let left = store.loadAll().records
        XCTAssertEqual(left.count, 10)
        XCTAssertTrue(left.contains { $0.sessionId == "active" }, "running work is never removed")
        XCTAssertEqual(res.deleted, 21)
        XCTAssertFalse(left.contains { $0.sessionId == "old0" }, "oldest finished records go first")
    }

    func testHiddenSessionReappearsOnActivityAndUnknownIsNeverRemoved() throws {
        let store = SessionStore(paths: paths)
        var fin = apply((start + [ev(.userPromptSubmit, "f", t: 1), bgStop(2, [])]).map { var e = $0; e.sessionId = "f"; return e })
        fin.pid = getpid(); fin.pidStartTime = ProcessInspector.info(getpid())?.startTime
        var unk = apply([ev(.userPromptSubmit, "u", t: 1), ev(.stop, "u", t: 2)])   // Stop without background report
        unk.pid = getpid(); unk.pidStartTime = fin.pidStartTime
        try store.withLock { try store.save(fin); try store.save(unk) }
        let res = SessionMaintenance.cleanup(store: store, now: 10, retention: nil, alive: SessionMaintenance.liveness)
        XCTAssertEqual(res.dismissed, 1)
        XCTAssertEqual(res.deleted, 0)
        let recs = Dictionary(uniqueKeysWithValues: store.loadAll().records.map { ($0.sessionId, $0) })
        XCTAssertEqual(recs["f"]?.dismissed, true)
        XCTAssertNil(recs["u"]?.dismissed, "Unknown (background not reported) is kept visible")
        let resumed = StateMachine.reduce(recs["f"], ev(.userPromptSubmit, "f", t: 20))
        XCTAssertNil(resumed.dismissed)
        XCTAssertEqual(resumed.state, .working)
    }

    // MARK: Diagnostic report sanitization

    func testDiagnosticReportContainsNoIdentifiersNamesOrPaths() {
        let sid = "0f3c2a1e-5b7d-4c2a-9e11-3d5f7a9b1c2e"
        var r = apply([ev(.sessionStart, sid, t: 1, source: "startup", cwd: "/Users/alice/Developer/TopSecretProject")])
        r.gitRepoName = "TopSecretRepo"; r.worktreeName = "feature-xyz-private"; r.projectName = "TopSecretRepo"
        r.pid = 4242
        let e = Presentation.evaluate(r, now: 10, alive: true, lastWake: nil)
        let p = DetectedProcess(pid: 4242, startTime: 1, client: .desktop, cwd: "/Users/alice/Developer/TopSecretProject")
        let health = MonitoringHealth(hookStatus: HookInstallStatus(kind: .installed, installedEvents: [], missingEvents: [], duplicateEvents: [], mismatchedCommand: false, detail: nil), hookExecutablePresent: true, storeAccessible: true,
                                      lastEventAt: 9, corruptRecords: 0, unobservedClaudeProcesses: 0, problems: [])
        let log = """
        2026-11-27T16:26:21Z PreToolUse 0f3c2a1e ok 1665us bytes=1028
        2026-11-27T16:26:22Z Stop 0f3c2a1e ok 1500us bytes=900 bg=1(shell:running) wake=0 cron=0
        2026-11-27T16:26:23Z - - rejected:malformedJSON 300us bytes=4
        """
        var input = DiagnosticReport.Input(version: "1.1.0", osVersion: "Version 27.2", architecture: "arm64", health: health,
                                           appRunning: true, sessions: [e], processes: [p],
                                           processVersions: [4242: DiagnosticReport.clientVersion(fromExecutable: "/Users/alice/Library/Application Support/Claude/claude-code/2.1.330/x/claude.app/Contents/MacOS/claude")!],
                                           hookLogTail: log, settingsFileName: "settings.json", now: 10)
        input.sensitive = ["alice", "/Users/alice", "Alice Example"]
        let text = DiagnosticReport.render(input)
        for leak in ["alice", "Alice", "TopSecret", "feature-xyz", sid, "0f3c2a1e", "/Users", "Developer/", "bytes="] {
            XCTAssertFalse(text.contains(leak), "report leaks \(leak):\n\(text)")
        }
        XCTAssertTrue(text.contains("Desktop 2.1.330"))
        XCTAssertTrue(text.contains("| Stop | 1 |"))
        XCTAssertTrue(text.contains("rejected:malformedJSON×1"))
        XCTAssertTrue(text.contains("S1 (project 1)"))
        var named = input
        named.includeNames = true
        XCTAssertTrue(DiagnosticReport.render(named).contains("TopSecretRepo"), "--include-names opts in to names")
        XCTAssertFalse(DiagnosticReport.render(named).contains("/Users/alice"), "paths are never included")
    }

    func testScrubberRemovesPathsIdsAndEmails() {
        let s = DiagnosticReport.scrub("x /Users/bob/p y 0123456789abcdef0123 z bob@example.com /var/folders/ab/c 1f2e3d4c-0000-4000-8000-123456789abc",
                                       sensitive: [])
        XCTAssertFalse(s.contains("bob"))
        XCTAssertFalse(s.contains("0123456789abcdef"))
        XCTAssertFalse(s.contains("/var/folders"))
        XCTAssertFalse(s.contains("1f2e3d4c"))
        XCTAssertEqual(DiagnosticReport.clientVersion(fromExecutable: "/Users/x/.local/share/claude/versions/2.1.325"), "2.1.325")
        XCTAssertNil(DiagnosticReport.clientVersion(fromExecutable: "/usr/local/bin/claude"))
    }

    // MARK: Parser

    func testInternalAgentFlagParsedFromEmptyAgentType() throws {
        let e = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "SubagentStop", "agent_id": "a1", "agent_type": "",
                                                "background_tasks": [], "last_assistant_message": "SECRET"]), timestamp: 1)
        XCTAssertTrue(e.isInternalAgent)
        let f = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "SubagentStop", "agent_id": "a1", "agent_type": "Explore"]), timestamp: 1)
        XCTAssertFalse(f.isInternalAgent)
        XCTAssertEqual(f.agentType, "Explore")
        let g = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "SubagentStop", "agent_id": "a1"]), timestamp: 1)
        XCTAssertFalse(g.isInternalAgent, "absent agent_type is not evidence")
    }

    func testRecordsStayReadableByPreviousVersions() throws {
        // Rollback safety: new fields are optional and no new enum raw values are persisted.
        var r = apply(start + [ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"),
                               ev(.permissionRequest, t: 3, tool: "Bash")])
        r.backgroundActivityAt = 5
        let data = try JSONEncoder().encode(r)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(obj["schemaVersion"] as? Int, 1)
        let v102Reasons: Set<String> = ["started", "resumed", "permission", "question", "planApproval", "elicitation", "idleInput",
                                         "interrupted", "apiError", "ended", "observedMidTurn", "continued", "autoContinued"]
        for reason in [StateReason.interrupted, .idleInput, .question, .permission] { XCTAssertTrue(v102Reasons.contains(reason.rawValue)) }
        XCTAssertEqual(Set(StateReason.allCasesForTest.map(\.rawValue)), v102Reasons)
    }
}

extension StateReason {
    static var allCasesForTest: [StateReason] {
        [.started, .resumed, .permission, .question, .planApproval, .elicitation, .idleInput, .interrupted, .apiError, .ended,
         .observedMidTurn, .continued, .autoContinued]
    }
}

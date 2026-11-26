import XCTest
@testable import ClaudeStatusCore

/// Regression tests for the v1.0.0 monitoring defect: a Desktop session whose foreground
/// response finished while a background command kept running was shown as Complete, and after
/// "Clear Finished" it disappeared entirely ("No active sessions") although Claude was still
/// working and would continue automatically.
final class BackgroundAndDiscoveryTests: TempDirTestCase {
    let shellA = BackgroundTaskInfo(id: "task-a", type: "shell", status: "running")
    let shellB = BackgroundTaskInfo(id: "task-b", type: "shell", status: "running")
    let agent = BackgroundTaskInfo(id: "task-c", type: "subagent", status: "running")

    func stop(_ t: Double, _ bg: [BackgroundTaskInfo]?, crons: ScheduleCounts? = ScheduleCounts(), sid: String = "s1",
              agentId: String? = nil, name: HookEventName = .stop) -> HookEvent {
        var e = ev(name, sid, t: t, agent: agentId)
        e.backgroundTasks = bg
        e.schedules = bg == nil ? nil : crons
        return e
    }

    func view(_ r: SessionRecord, now: Double? = nil, alive: Bool? = true) -> EffectiveSession {
        Presentation.evaluate(r, now: now ?? r.lastEventAt + 1, alive: alive, lastWake: nil)
    }

    // MARK: The observed defect, step by step

    func testForegroundFinishWithBackgroundCommandStaysWorkingUntilAllWorkCompletes() {
        // 3. Foreground turn begins.
        var r = apply([ev(.sessionStart, t: 1, source: "startup"), ev(.userPromptSubmit, t: 2)])
        XCTAssertEqual(view(r).state, .working)
        XCTAssertEqual(view(r).activity, .foreground)
        // 4. The turn launches a background command (the Bash call returns immediately).
        r = apply([ev(.preToolUse, t: 3, tool: "Bash", toolUseId: "b1"), ev(.postToolUse, t: 4, tool: "Bash", toolUseId: "b1")], from: r)
        // 5. The foreground response finishes while the command continues.
        r = apply([stop(10, [shellA])], from: r)
        XCTAssertEqual(r.state, .complete, "the foreground turn itself did finish")
        // 6. The session remains Working — Background (v1.0.0 showed Complete here).
        var v = view(r, now: 600)
        XCTAssertEqual(v.state, .working)
        XCTAssertEqual(v.activity, .background)
        XCTAssertEqual(v.label, "Working — Background")
        XCTAssertEqual(v.backgroundActive, 1)
        XCTAssertEqual(Presentation.aggregate([v]), .working)
        XCTAssertFalse(Presentation.isRemovable(v, now: 600, retention: nil), "Clear Finished must keep it")
        // Desktop runs an internal agent after Stop; its SubagentStop carries the parent's tasks.
        r = apply([stop(12, [shellA], agentId: nil, name: .subagentStop)], from: r)
        XCTAssertEqual(view(r).activity, .background)
        // 7. The command completes and Claude resumes on its own (no prompt typed).
        r = apply([ev(.preToolUse, t: 300, tool: "Bash", toolUseId: "b2")], from: r)
        // 8. Foreground Working again, marked as an automatic continuation.
        v = view(r)
        XCTAssertEqual(v.state, .working)
        XCTAssertEqual(v.activity, .foreground)
        XCTAssertEqual(r.reason, .autoContinued)
        XCTAssertEqual(v.label, "Working — Continuing")
        // 9./10. All work completes: Complete only now, on a Stop reporting no background work.
        r = apply([ev(.postToolUse, t: 301, tool: "Bash", toolUseId: "b2"), stop(310, [])], from: r)
        v = view(r)
        XCTAssertEqual(v.state, .complete)
        XCTAssertEqual(v.confidence, .confirmed)
    }

    func testAutomaticContinuationThatStartsWithUserPromptSubmit() {
        // Background subagents and scheduled tasks report back through UserPromptSubmit.
        var r = apply([ev(.userPromptSubmit, t: 1), stop(5, [agent])])
        XCTAssertEqual(view(r).activity, .background)
        r = apply([ev(.subagentStop, t: 60, agent: "a1"), ev(.userPromptSubmit, t: 61)], from: r)
        XCTAssertEqual(view(r).state, .working)
        XCTAssertEqual(view(r).activity, .foreground)
        r = apply([stop(70, [])], from: r)
        XCTAssertEqual(view(r).state, .complete)
    }

    func testStopWithoutBackgroundReportIsUnknownNotComplete() {
        let r = apply([ev(.userPromptSubmit, t: 1), stop(5, nil)])
        let v = view(r)
        XCTAssertEqual(r.state, .complete)
        XCTAssertEqual(v.state, .unknown)
        XCTAssertEqual(v.confidence, .unknown)
        XCTAssertEqual(v.backgroundSummary, "Not reported")
        XCTAssertFalse(Presentation.isRemovable(v, now: 10, retention: nil))
    }

    // MARK: 11. Cancellation and failure

    func testCancelledAndFailedBackgroundTasksDoNotCountAsRunning() {
        let killed = BackgroundTaskInfo(id: "k", type: "shell", status: "killed")
        let failed = BackgroundTaskInfo(id: "f", type: "shell", status: "failed")
        let done = BackgroundTaskInfo(id: "d", type: "shell", status: "completed")
        var r = apply([ev(.userPromptSubmit, t: 1), stop(5, [killed, failed, done])])
        XCTAssertEqual(view(r).state, .complete)
        // An unrecognised status is treated as still running (conservative).
        r = apply([ev(.userPromptSubmit, t: 6), stop(9, [BackgroundTaskInfo(id: "n", type: "shell", status: "paused_new")])], from: r)
        XCTAssertEqual(view(r).activity, .background)
        // Cancellation then automatic continuation then completion.
        r = apply([ev(.preToolUse, t: 20, tool: "TaskStop", toolUseId: "x"), ev(.postToolUse, t: 21, tool: "TaskStop", toolUseId: "x"),
                   stop(25, [])], from: r)
        XCTAssertEqual(view(r).state, .complete)
    }

    func testBackgroundFailureFollowedByApiErrorIsError() {
        let r = apply([ev(.userPromptSubmit, t: 1), stop(5, [shellA]), ev(.userPromptSubmit, t: 50), ev(.stopFailure, t: 55, error: "rate_limit")])
        let v = view(r)
        XCTAssertEqual(v.state, .error)
        XCTAssertTrue(v.detail.contains("1 background task"), "background work still visible in the detail")
    }

    // MARK: 12. Concurrent Desktop and CLI sessions

    func testConcurrentDesktopBackgroundAndCliForeground() {
        var d = apply([ev(.userPromptSubmit, "desk", t: 1), stop(5, [shellA], sid: "desk")])
        d.client = .desktop
        var c = apply([ev(.userPromptSubmit, "cli", t: 2)])
        c.client = .cli
        let both = [view(d, now: 6), view(c, now: 6)]
        XCTAssertEqual(Presentation.aggregate(both), .working)
        XCTAssertEqual(Presentation.aggregateActivity(both), .foreground)
        let counts = Presentation.counts(both)
        XCTAssertEqual(counts.working, 2)
        XCTAssertEqual(counts.background, 1)
        XCTAssertEqual(Presentation.summary(counts), "1 working · 1 background")
        c = apply([stop(7, [], sid: "cli")], from: c)
        let later = [view(d, now: 8), view(c, now: 8)]
        XCTAssertEqual(Presentation.aggregate(later), .working, "background work keeps the menu bar working")
        XCTAssertEqual(Presentation.aggregateActivity(later), .background)
    }

    // MARK: 13. Multiple simultaneous background tasks

    func testMultipleBackgroundTasksDrainOneByOne() {
        var r = apply([ev(.userPromptSubmit, t: 1), stop(5, [shellA, shellB, agent])])
        XCTAssertEqual(view(r).backgroundActive, 3)
        XCTAssertEqual(view(r).detail, "3 background tasks running (2 shell, subagent)")
        r = apply([ev(.preToolUse, t: 40, tool: "Bash", toolUseId: "1"), ev(.postToolUse, t: 41, tool: "Bash", toolUseId: "1"),
                   stop(45, [shellB, agent])], from: r)
        XCTAssertEqual(view(r).activity, .background)
        XCTAssertEqual(view(r).backgroundActive, 2)
        r = apply([ev(.userPromptSubmit, t: 80), stop(85, [shellB])], from: r)
        XCTAssertEqual(view(r).backgroundActive, 1)
        r = apply([ev(.preToolUse, t: 120, tool: "Bash", toolUseId: "2"), stop(125, [])], from: r)
        XCTAssertEqual(view(r).state, .complete)
    }

    // MARK: 14. Missing and out-of-order events

    func testOutOfOrderStopDoesNotOverrideNewerBackgroundReport() {
        var r = apply([ev(.userPromptSubmit, t: 1), stop(50, [shellA])])
        r = apply([stop(40, [])], from: r)   // older event delivered late
        XCTAssertEqual(view(r).activity, .background)
        XCTAssertEqual(r.ignoredOutOfOrder, 1)
    }

    func testMissingContinuationEventsEventuallyBecomeUnknownNeverComplete() {
        let r = apply([ev(.userPromptSubmit, t: 1), stop(5, [shellA])])
        XCTAssertEqual(view(r, now: 5 + 3 * 3600).state, .working, "long background commands are normal")
        let v = view(r, now: 5 + 9 * 3600)
        XCTAssertEqual(v.state, .unknown)
        XCTAssertTrue(v.stale)
        XCTAssertNotEqual(v.state, .complete)
    }

    func testProcessExitWhileBackgroundReportedIsUnknown() {
        let r = apply([ev(.userPromptSubmit, t: 1), stop(5, [shellA])])
        let v = view(r, alive: false)
        XCTAssertEqual(v.state, .unknown)
        XCTAssertFalse(v.ended)
        XCTAssertTrue(v.detail.contains("background"))
    }

    func testSessionRestartForgetsBackgroundOfPreviousProcess() {
        var r = apply([ev(.userPromptSubmit, t: 1), stop(5, [shellA])])
        r = apply([ev(.sessionStart, t: 10, source: "resume")], from: r)
        XCTAssertNil(r.background)
        r = apply([ev(.sessionEnd, t: 20)], from: apply([stop(15, [shellA])], from: r))
        XCTAssertEqual(r.background, [])
    }

    // MARK: Scheduled wakeups (session_crons)

    func testOneShotWakeupIsPendingContinuationRecurringIsInformational() {
        var r = apply([ev(.userPromptSubmit, t: 1), stop(5, [], crons: ScheduleCounts(oneShot: 1, recurring: 0))])
        XCTAssertEqual(view(r).state, .working)
        XCTAssertEqual(view(r).activity, .scheduled)
        r = apply([ev(.userPromptSubmit, t: 600), stop(610, [], crons: ScheduleCounts(oneShot: 0, recurring: 2))], from: r)
        XCTAssertEqual(view(r).state, .complete)
        XCTAssertTrue(view(r).detail.contains("2 recurring schedules"))
    }

    // MARK: 1./2./15. Existing sessions and discovery without restart

    func testUnobservedProcessesAreShownAsUnknownAndCountTowardsAggregate() {
        let procs = [DetectedProcess(pid: 4242, startTime: 100, client: .desktop, cwd: "/Users/demo/Code/acme-web"),
                     DetectedProcess(pid: 4343, startTime: 200, client: .cli, cwd: "/Users/demo/Code/docs-site")]
        let unobserved = Presentation.unobservedProcesses(procs, records: [])
        XCTAssertEqual(unobserved.count, 2)
        let rows = Presentation.unobservedSessions(unobserved, now: 1000)
        XCTAssertTrue(rows.allSatisfy { $0.unobserved && $0.state == .unknown && $0.confidence == .unknown })
        XCTAssertEqual(rows.first?.record.displayName, "acme-web")
        XCTAssertEqual(rows.first?.label, "Unknown — Not observed")
        XCTAssertEqual(Presentation.aggregate(rows), .unknown, "never Idle / 'no active sessions'")
        let c = Presentation.counts(rows)
        XCTAssertEqual(c.unobserved, 2)
        XCTAssertEqual(Presentation.summary(c), "2 unknown")
        XCTAssertFalse(rows.contains { Presentation.isRemovable($0, now: 1000, retention: nil) })
        // A completed session elsewhere must not turn the aggregate green.
        var done = SessionRecord(sessionId: "done", timestamp: 1); done.state = .complete; done.background = []
        XCTAssertEqual(Presentation.aggregate(rows + [view(done)]), .unknown)
    }

    func testDiscoveredSessionBecomesObservedOnItsNextEventWithoutRestart() {
        let p = DetectedProcess(pid: 4242, startTime: 100, client: .desktop, cwd: "/Users/demo/Code/acme-web")
        var ctx = HookContext(client: .desktop, entrypoint: "claude-desktop")
        ctx.pid = 4242
        ctx.pidStartTime = 100.2
        let r = StateMachine.reduce(nil, stop(500, [shellA]), context: ctx)
        XCTAssertTrue(Presentation.unobservedProcesses([p], records: [r]).isEmpty)
        XCTAssertEqual(view(r).activity, .background, "first event after discovery already gives the real state")
        // A reused PID (different start time) is not the same session.
        let reused = DetectedProcess(pid: 4242, startTime: 900, client: .cli, cwd: "/tmp")
        XCTAssertEqual(Presentation.unobservedProcesses([reused], records: [r]).count, 1)
        // A record without PID is matched by working directory.
        var nopid = SessionRecord(sessionId: "np", timestamp: 1); nopid.cwd = "/Users/demo/Code/acme-web"
        XCTAssertTrue(Presentation.unobservedProcesses([p], records: [nopid]).isEmpty)
    }

    // MARK: Clear Finished / retention never creates an unobserved session

    func testClearFinishedHidesLiveSessionsAndKeepsBackgroundWork() throws {
        let store = SessionStore(paths: paths)
        try paths.ensureDirectories()
        func put(_ sid: String, _ events: [HookEvent], pid: Int32?) throws {
            var r = apply(events)
            r.sessionId = sid
            r.pid = pid
            try store.save(r)
        }
        try put("bg", [ev(.userPromptSubmit, "bg", t: 1), stop(5, [shellA], sid: "bg")], pid: 11)
        try put("done-live", [ev(.userPromptSubmit, "done-live", t: 1), stop(5, [], sid: "done-live")], pid: 12)
        try put("done-dead", [ev(.userPromptSubmit, "done-dead", t: 1), stop(5, [], sid: "done-dead")], pid: 13)
        let alive: (SessionRecord) -> Bool? = { $0.pid == 13 ? false : true }
        let res = SessionMaintenance.cleanup(store: store, now: 10, retention: nil, alive: alive)
        XCTAssertEqual(res.deleted, 1)
        XCTAssertEqual(res.dismissed, 1)
        guard case .record(let bg) = store.load("bg"), case .record(let live) = store.load("done-live") else {
            return XCTFail("background and live records must be kept")
        }
        XCTAssertNil(bg.dismissed)
        XCTAssertEqual(live.dismissed, true)
        XCTAssertEqual(store.load("done-dead"), .missing)
        // Hidden sessions keep their process observed and leave the aggregate.
        let hidden = view(live)
        XCTAssertTrue(hidden.dismissed)
        XCTAssertEqual(Presentation.aggregate([hidden]), .idle)
        XCTAssertTrue(Presentation.unobservedProcesses([DetectedProcess(pid: 12, startTime: 0, client: .cli, cwd: nil)],
                                                       records: [live]).isEmpty)
        // The next event shows it again.
        let again = StateMachine.reduce(live, ev(.userPromptSubmit, "done-live", t: 20))
        XCTAssertNil(again.dismissed)
        // Retention never deletes a record whose process is alive.
        let ret = SessionMaintenance.cleanup(store: store, now: 1e9, retention: 3600, alive: alive)
        XCTAssertEqual(ret.deleted, 0)
        XCTAssertNotEqual(store.load("done-live"), .missing)
    }

    // MARK: 16. Monitoring failures vs. successful inactivity

    func testHealthDistinguishesCoverageGapsHookFailuresAndInactivity() throws {
        try paths.ensureDirectories()
        let settings = write(#"{"hooks":{}}"#, to: "settings.json")
        _ = try HookConfigurator(settingsURL: settings, hookCommandPath: paths.hookExecutable.path, backupsDir: paths.backupsDir).install()
        try FileManager.default.createDirectory(at: paths.hookExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: paths.hookExecutable)
        chmod(paths.hookExecutable.path, 0o755)

        let idle = MonitoringHealth.check(paths: paths, settingsURL: settings, records: [], corrupt: 0, processes: [])
        XCTAssertEqual(idle.level, .ok)
        XCTAssertEqual(idle.coverageText, "No Claude Code sessions running")

        let p = DetectedProcess(pid: 77, startTime: 1, client: .desktop, cwd: "/x")
        let gap = MonitoringHealth.check(paths: paths, settingsURL: settings, records: [], corrupt: 0, processes: [p])
        XCTAssertEqual(gap.level, .warning)
        XCTAssertFalse(gap.coverageComplete)
        XCTAssertEqual(gap.coverageText, "0 of 1 running session observed")
        XCTAssertTrue(gap.summary.hasPrefix("Monitoring incomplete"))

        var rec = SessionRecord(sessionId: "s", timestamp: 1); rec.pid = 77; rec.pidStartTime = 1
        rec.lastCompletedAt = 1; rec.backgroundReportedAt = 1
        let full = MonitoringHealth.check(paths: paths, settingsURL: settings, records: [rec], corrupt: 0, processes: [p])
        XCTAssertEqual(full.level, .ok)
        XCTAssertEqual(full.summary, "Monitoring all 1 running session")
        XCTAssertEqual(full.backgroundVisibility, .supported)

        DiagnosticsLog(url: paths.hookLog).append("2026-01-01T00:00:00Z - - rejected:invalidSessionId 10us bytes=5")
        let failing = MonitoringHealth.check(paths: paths, settingsURL: settings, records: [rec], corrupt: 0, processes: [p])
        XCTAssertEqual(failing.recentHookFailures, 1)
        XCTAssertEqual(failing.level, .warning)

        rec.backgroundReportedAt = nil
        let noBg = MonitoringHealth.check(paths: paths, settingsURL: settings, records: [rec], corrupt: 0, processes: [p])
        XCTAssertEqual(noBg.backgroundVisibility, .notReported)
    }

    // MARK: Parsing and privacy

    func testParserKeepsOnlyIdTypeAndStatus() throws {
        let secret = "SECRET-COMMAND-TEXT"
        let payload = json(["session_id": "s1", "hook_event_name": "Stop", "last_assistant_message": secret,
                            "background_tasks": [["id": "t-1", "type": "shell", "status": "running", "command": secret, "description": secret],
                                                 ["id": "../../etc", "type": "cloud session", "status": "running"],
                                                 ["type": "MCP task"], "garbage"],
                            "session_crons": [["id": "c", "recurring": false, "prompt": secret], ["id": "d", "recurring": true]]])
        let e = try HookEventParser.parse(payload, timestamp: 1)
        XCTAssertEqual(e.backgroundTasks?.count, 4)
        XCTAssertEqual(e.backgroundTasks?[0], BackgroundTaskInfo(id: "t-1", type: "shell", status: "running"))
        XCTAssertEqual(e.backgroundTasks?[1].id, "#1", "invalid identifiers are replaced")
        XCTAssertEqual(e.backgroundTasks?[1].type, "cloud session")
        XCTAssertEqual(e.backgroundTasks?[2].status, "unknown")
        XCTAssertEqual(e.schedules, ScheduleCounts(oneShot: 1, recurring: 1))
        let r = StateMachine.reduce(nil, e)
        let stored = try JSONEncoder().encode(r)
        XCTAssertNil(stored.range(of: Data(secret.utf8)))
        XCTAssertEqual(HookRunner.evidence(e), "bg=4(shell:running,cloud_session:running,MCP_task:unknown,task:unknown) wake=1 cron=1")
        let none = try HookEventParser.parse(json(["session_id": "s1", "hook_event_name": "Stop"]), timestamp: 1)
        XCTAssertNil(none.backgroundTasks)
        XCTAssertEqual(HookRunner.evidence(none), "bg=?")
    }

    func testOlderRecordsWithoutNewFieldsStillDecode() throws {
        let v1 = #"{"activeSubagents":0,"client":"desktop","ended":false,"eventCount":3,"firstSeenAt":1,"ignoredOutOfOrder":0,"inFlightTools":[],"lastEventAt":5,"lastEventName":"Stop","lastTurnDurationExact":true,"observedMidSession":false,"schemaVersion":1,"sessionId":"old","state":"complete","turnObservedFromStart":true,"turnSeq":1,"backgroundTasks":1}"#
        let r = try JSONDecoder().decode(SessionRecord.self, from: Data(v1.utf8))
        XCTAssertNil(r.background)
        XCTAssertEqual(view(r).state, .unknown, "a v1.0.0 Complete record without a background report is not trusted")
    }

    func testClientClassification() {
        XCTAssertEqual(ProcessInspector.classify(executable: "/Users/x/Library/Application Support/Claude/claude-code/2.1/claude.app/Contents/MacOS/claude", ancestorExecutables: []), .desktop)
        XCTAssertEqual(ProcessInspector.classify(executable: "/opt/homebrew/bin/claude", ancestorExecutables: ["/Applications/Claude.app/Contents/Helpers/disclaimer"]), .desktop)
        XCTAssertEqual(ProcessInspector.classify(executable: "/Users/x/.local/bin/claude", ancestorExecutables: ["/bin/zsh"]), .cli)
        XCTAssertNotNil(ProcessInspector.workingDirectory(getpid()))
    }
}

import XCTest
@testable import ClaudeStatusCore

final class StateMachineTests: XCTestCase {
    func testNewSessionThenFullTurn() {
        var r = apply([ev(.sessionStart, t: 1, source: "startup")])
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(r.reason, .started)
        XCTAssertFalse(r.observedMidSession)
        r = apply([ev(.userPromptSubmit, t: 2), ev(.preToolUse, t: 3, tool: "Bash", toolUseId: "a"),
                 ev(.postToolUse, t: 4, tool: "Bash", toolUseId: "a")], from: r)
        XCTAssertEqual(r.state, .working)
        XCTAssertEqual(r.turnStartedAt, 2)
        XCTAssertTrue(r.inFlightTools.isEmpty)
        r = apply([ev(.stop, t: 12)], from: r)
        XCTAssertEqual(r.state, .complete)
        XCTAssertEqual(r.lastTurnDuration, 10)
        XCTAssertTrue(r.lastTurnDurationExact)
        XCTAssertEqual(r.lastCompletedAt, 12)
        XCTAssertNil(r.turnStartedAt)
        XCTAssertEqual(r.turnSeq, 1)
    }

    func testMultipleTurns() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.stop, t: 2), ev(.userPromptSubmit, t: 5), ev(.stop, t: 9)])
        XCTAssertEqual(r.state, .complete)
        XCTAssertEqual(r.turnSeq, 2)
        XCTAssertEqual(r.lastTurnDuration, 4)
    }

    func testPermissionRequestWaitsThenResumes() {
        var r = apply([ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "Bash", toolUseId: "a"), ev(.permissionRequest, t: 3, tool: "Bash")])
        XCTAssertEqual(r.state, .waiting)
        XCTAssertEqual(r.reason, .permission)
        r = apply([ev(.notification, t: 4, notification: "permission_prompt")], from: r)
        XCTAssertEqual(r.state, .waiting)
        r = apply([ev(.postToolUse, t: 10, tool: "Bash", toolUseId: "a")], from: r)
        XCTAssertEqual(r.state, .working)
        XCTAssertNil(r.reason)
        XCTAssertEqual(r.turnStartedAt, 1, "approval does not restart the turn clock")
    }

    func testPermissionDeniedThenClaudeContinuesOrStops() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.permissionRequest, t: 2), ev(.stop, t: 3)])
        XCTAssertEqual(r.state, .complete)
    }

    func testAskUserQuestionAndPlanApprovalAreWaiting() {
        var r = apply([ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, tool: "AskUserQuestion", toolUseId: "q")])
        XCTAssertEqual(r.state, .waiting)
        XCTAssertEqual(r.reason, .question)
        r = apply([ev(.postToolUse, t: 3, tool: "AskUserQuestion", toolUseId: "q")], from: r)
        XCTAssertEqual(r.state, .working)
        r = apply([ev(.preToolUse, t: 4, tool: "ExitPlanMode", toolUseId: "p")], from: r)
        XCTAssertEqual(r.reason, .planApproval)
    }

    func testElicitationNotifications() {
        var r = apply([ev(.userPromptSubmit, t: 1), ev(.notification, t: 2, notification: "elicitation_dialog")])
        XCTAssertEqual(r.state, .waiting)
        XCTAssertEqual(r.reason, .elicitation)
        r = apply([ev(.notification, t: 3, notification: "elicitation_complete")], from: r)
        XCTAssertEqual(r.state, .working)
    }

    func testToolFailureDoesNotEndTurn() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, toolUseId: "a"), ev(.postToolUseFailure, t: 3, toolUseId: "a")])
        XCTAssertEqual(r.state, .working)
        XCTAssertTrue(r.inFlightTools.isEmpty)
    }

    func testInterruptIsCancellationNotError() {
        // A user cancellation is not a terminal failure: it ends the turn (Idle — Interrupted),
        // never Error (red) and never Complete.
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.preToolUse, t: 2, toolUseId: "a"), ev(.postToolUseFailure, t: 5, toolUseId: "a", interrupt: true)])
        XCTAssertEqual(r.state, .idle)
        XCTAssertEqual(r.reason, .interrupted)
        XCTAssertNil(r.errorCategory)
        XCTAssertEqual(Presentation.evaluate(r, now: 6, alive: true, lastWake: nil).label, "Idle — Interrupted")
        XCTAssertEqual(r.lastTurnDuration, 4)
        // The next prompt clears the error.
        let r2 = apply([ev(.userPromptSubmit, t: 6)], from: r)
        XCTAssertEqual(r2.state, .working)
        XCTAssertNil(r2.errorCategory)
    }

    func testSubagentInterruptDoesNotEndParentTurn() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.postToolUseFailure, t: 2, agent: "sub", interrupt: true)])
        XCTAssertEqual(r.state, .working)
    }

    func testStopFailureIsError() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.stopFailure, t: 2, error: "rate_limit")])
        XCTAssertEqual(r.state, .error)
        XCTAssertEqual(r.reason, .apiError)
        XCTAssertEqual(r.errorCategory, "rate_limit")
    }

    func testSubagentStopNeverCompletesParent() {
        var r = apply([ev(.userPromptSubmit, t: 1), ev(.subagentStart, t: 2, agent: "a1"),
                     ev(.preToolUse, t: 3, agent: "a1", toolUseId: "x"), ev(.postToolUse, t: 4, agent: "a1", toolUseId: "x"),
                     ev(.subagentStop, t: 5, agent: "a1")])
        XCTAssertEqual(r.state, .working)
        XCTAssertEqual(r.activeSubagents, 0)
        // A Stop carrying agent_id (teammate/subagent) is not the main thread completing.
        r = apply([ev(.stop, t: 6, agent: "a1")], from: r)
        XCTAssertEqual(r.state, .working)
        r = apply([ev(.stop, t: 7)], from: r)
        XCTAssertEqual(r.state, .complete)
    }

    func testBackgroundSubagentActivityAfterStopKeepsComplete() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.stop, t: 2), ev(.preToolUse, t: 3, agent: "bg", toolUseId: "z"),
                     ev(.postToolUse, t: 4, agent: "bg", toolUseId: "z")])
        XCTAssertEqual(r.state, .complete)
    }

    func testStopHookContinuationReopensTurn() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.stop, t: 2), ev(.preToolUse, t: 3, toolUseId: "c")])
        XCTAssertEqual(r.state, .working)
        XCTAssertEqual(r.reason, .continued)
        let r2 = apply([ev(.stop, t: 4)], from: r)
        XCTAssertEqual(r2.state, .complete)
    }

    func testDuplicateEventsAreIdempotent() {
        let a = apply([ev(.userPromptSubmit, t: 1), ev(.stop, t: 2)])
        let b = apply([ev(.userPromptSubmit, t: 1), ev(.userPromptSubmit, t: 1), ev(.stop, t: 2), ev(.stop, t: 2)])
        XCTAssertEqual(a.state, b.state)
        XCTAssertEqual(a.lastTurnDuration, b.lastTurnDuration)
        let c = apply([ev(.userPromptSubmit, t: 1), ev(.permissionRequest, t: 2), ev(.permissionRequest, t: 2)])
        XCTAssertEqual(c.state, .waiting)
    }

    func testOutOfOrderEventsIgnored() {
        let r = apply([ev(.userPromptSubmit, t: 10), ev(.stop, t: 20), ev(.postToolUse, t: 15, toolUseId: "late")])
        XCTAssertEqual(r.state, .complete)
        XCTAssertEqual(r.ignoredOutOfOrder, 1)
        XCTAssertEqual(r.lastEventAt, 20)
    }

    func testBackwardsClockJumpIsNotTreatedAsReordering() {
        let r = apply([ev(.userPromptSubmit, t: 10_000), ev(.stop, t: 10_000 - 3600)])
        XCTAssertEqual(r.state, .complete, "an hour-old timestamp is a clock change, not a reorder")
        XCTAssertEqual(r.ignoredOutOfOrder, 0)
    }

    func testMissingSessionStartObservedMidTurn() {
        let r = apply([ev(.preToolUse, t: 5, toolUseId: "a")])
        XCTAssertEqual(r.state, .working)
        XCTAssertEqual(r.reason, .observedMidTurn)
        XCTAssertTrue(r.observedMidSession)
        XCTAssertFalse(r.turnObservedFromStart)
        let done = apply([ev(.stop, t: 9)], from: r)
        XCTAssertEqual(done.lastTurnDuration, 4)
        XCTAssertFalse(done.lastTurnDurationExact)
    }

    func testFirstEventStopIsComplete() {
        let r = apply([ev(.stop, t: 5)])
        XCTAssertEqual(r.state, .complete)
        XCTAssertNil(r.lastTurnDuration)
    }

    func testUnknownStateUntilEvidence() {
        let r = apply([ev(.subagentStart, t: 1, agent: "x")])
        XCTAssertEqual(r.state, .unknown)
        let n = apply([ev(.notification, t: 1, notification: "auth_success")])
        XCTAssertEqual(n.state, .unknown)
    }

    func testIdlePromptSemantics() {
        let afterStop = apply([ev(.userPromptSubmit, t: 1), ev(.stop, t: 2), ev(.notification, t: 62, notification: "idle_prompt")])
        XCTAssertEqual(afterStop.state, .complete, "idle prompt after Stop is just 'ready'")
        let noStop = apply([ev(.userPromptSubmit, t: 1), ev(.notification, t: 62, notification: "idle_prompt")])
        XCTAssertEqual(noStop.state, .idle, "Claude is at its input prompt: the turn ended without a Stop")
        XCTAssertEqual(noStop.reason, .idleInput)
    }

    func testSessionEndAndResume() {
        var r = apply([ev(.userPromptSubmit, t: 1), ev(.stop, t: 2), ev(.sessionEnd, t: 3)])
        XCTAssertTrue(r.ended)
        XCTAssertEqual(r.state, .idle)
        r = apply([ev(.sessionStart, t: 10, source: "resume")], from: r)
        XCTAssertFalse(r.ended)
        XCTAssertEqual(r.reason, .resumed)
        r = apply([ev(.userPromptSubmit, t: 11)], from: r)
        XCTAssertEqual(r.state, .working)
    }

    func testSessionEndMidTurnRecordsDuration() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.sessionEnd, t: 4)])
        XCTAssertTrue(r.ended)
        XCTAssertEqual(r.lastTurnDuration, 3)
    }

    func testCompactionMidTurnKeepsWorking() {
        let r = apply([ev(.userPromptSubmit, t: 1), ev(.sessionStart, t: 2, source: "compact")])
        XCTAssertEqual(r.state, .working)
        let resumeActive = apply([ev(.userPromptSubmit, t: 1), ev(.sessionStart, t: 2, source: "resume")])
        XCTAssertEqual(resumeActive.state, .working)
        let clear = apply([ev(.userPromptSubmit, t: 1), ev(.sessionStart, t: 2, source: "clear")])
        XCTAssertEqual(clear.state, .idle)
    }

    func testConcurrentSessionsAreIndependent() {
        var store: [String: SessionRecord] = [:]
        let events = [ev(.userPromptSubmit, "A", t: 1), ev(.userPromptSubmit, "B", t: 1.5), ev(.permissionRequest, "B", t: 2),
                      ev(.stop, "A", t: 3), ev(.userPromptSubmit, "C", t: 3.5)]
        for e in events { store[e.sessionId] = StateMachine.reduce(store[e.sessionId], e) }
        XCTAssertEqual(store["A"]?.state, .complete)
        XCTAssertEqual(store["B"]?.state, .waiting)
        XCTAssertEqual(store["C"]?.state, .working)
    }

    func testContextAndProjectInfoApplied() {
        let ctx = HookContext(client: .cli, entrypoint: "cli", projectDir: "/p/root", pid: 4242, pidStartTime: 99)
        let r = StateMachine.reduce(nil, ev(.userPromptSubmit, t: 1, cwd: "/p/root/.claude/worktrees/feat"), context: ctx) { _ in
            ProjectInfo(repoRoot: "/p/root/.claude/worktrees/feat", repoName: "root", worktreeName: "feat")
        }
        XCTAssertEqual(r.client, .cli)
        XCTAssertEqual(r.pid, 4242)
        XCTAssertEqual(r.gitRepoName, "root")
        XCTAssertEqual(r.worktreeName, "feat")
        XCTAssertEqual(r.displayName, "root")
        // An unknown client in a later event does not erase a known one.
        let r2 = StateMachine.reduce(r, ev(.stop, t: 2), context: HookContext())
        XCTAssertEqual(r2.client, .cli)
    }

    func testInFlightToolsBounded() {
        var r: SessionRecord? = nil
        for i in 0..<200 { r = StateMachine.reduce(r, ev(.preToolUse, t: Double(i), toolUseId: "t\(i)")) }
        XCTAssertEqual(r?.inFlightTools.count, SessionRecord.maxInFlightTools)
    }

    func testUnregisteredEventOnlyUpdatesActivity() {
        let base = apply([ev(.userPromptSubmit, t: 1), ev(.stop, t: 2)])
        let e = HookEvent(name: nil, rawName: "PostToolBatch", sessionId: "s1", timestamp: 3)
        let r = StateMachine.reduce(base, e)
        XCTAssertEqual(r.state, .complete)
        XCTAssertEqual(r.lastEventAt, 3)
    }
}

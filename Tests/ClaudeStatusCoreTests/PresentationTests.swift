import XCTest
@testable import ClaudeStatusCore

final class PresentationTests: XCTestCase {
    func rec(_ state: SessionState, id: String = UUID().uuidString, last: Double = 1000) -> SessionRecord {
        var r = SessionRecord(sessionId: id, timestamp: last)
        r.state = state
        r.lastEventAt = last
        return r
    }

    func eff(_ s: SessionState) -> EffectiveSession {
        Presentation.evaluate(rec(s), now: 1001, alive: true, lastWake: nil)
    }

    func testAggregatePrecedence() {
        XCTAssertEqual(Presentation.aggregate([]), .idle)
        XCTAssertEqual(Presentation.aggregate([eff(.complete), eff(.working), eff(.waiting), eff(.error)]), .waiting)
        XCTAssertEqual(Presentation.aggregate([eff(.complete), eff(.working), eff(.error)]), .error)
        XCTAssertEqual(Presentation.aggregate([eff(.complete), eff(.working), eff(.unknown)]), .working)
        XCTAssertEqual(Presentation.aggregate([eff(.complete), eff(.unknown), eff(.idle)]), .unknown)
        XCTAssertEqual(Presentation.aggregate([eff(.complete), eff(.idle)]), .complete)
        XCTAssertEqual(Presentation.aggregate([eff(.idle)]), .idle)
        // Exhaustive: the aggregate equals the min-precedence member for every pair.
        for a in SessionState.allCases { for b in SessionState.allCases {
            let agg = Presentation.aggregate([eff(a), eff(b)])
            XCTAssertEqual(agg, a.precedence <= b.precedence ? a : b)
        } }
    }

    func testCountsPreserveWorkingVisibility() {
        let c = Presentation.counts([eff(.waiting), eff(.working), eff(.working), eff(.complete)])
        XCTAssertEqual(c.working, 2)
        XCTAssertEqual(c.waiting, 1)
        XCTAssertEqual(c.active, 3)
    }

    func testEndedSessionsExcludedFromAggregate() {
        var r = rec(.idle)
        r.ended = true
        let e = Presentation.evaluate(r, now: 2000, alive: nil, lastWake: nil)
        XCTAssertTrue(e.ended)
        XCTAssertEqual(Presentation.aggregate([e, eff(.complete)]), .complete)
    }

    func testLongRunningTurnIsNotStale() {
        var r = rec(.working, last: 1000)
        r.inFlightTools = ["build"]
        let e = Presentation.evaluate(r, now: 1000 + 60 * 60, alive: true, lastWake: nil)
        XCTAssertEqual(e.state, .working, "a one-hour tool call is still working")
        let e2 = Presentation.evaluate(r, now: 1000 + 3 * 3600, alive: true, lastWake: nil)
        XCTAssertEqual(e2.state, .unknown)
        XCTAssertTrue(e2.stale)
    }

    func testSilentTurnWithoutToolBecomesUnknownNotComplete() {
        let r = rec(.working, last: 1000)
        XCTAssertEqual(Presentation.evaluate(r, now: 1000 + 600, alive: true, lastWake: nil).state, .working)
        let e = Presentation.evaluate(r, now: 1000 + 21 * 60, alive: true, lastWake: nil)
        XCTAssertEqual(e.state, .unknown, "never Complete merely because events stopped")
    }

    func testSleepDoesNotCountTowardsStaleness() {
        let r = rec(.working, last: 1000)
        let e = Presentation.evaluate(r, now: 1000 + 8 * 3600, alive: true, lastWake: 1000 + 8 * 3600 - 60)
        XCTAssertEqual(e.state, .working)
    }

    func testWaitingNeverGoesStale() {
        let r = rec(.waiting, last: 1000)
        XCTAssertEqual(Presentation.evaluate(r, now: 1000 + 86400, alive: true, lastWake: nil).state, .waiting)
    }

    func testProcessExit() {
        let w = Presentation.evaluate(rec(.working), now: 1001, alive: false, lastWake: nil)
        XCTAssertEqual(w.state, .unknown)
        XCTAssertTrue(w.processExited)
        let c = Presentation.evaluate(rec(.complete), now: 1001, alive: false, lastWake: nil)
        XCTAssertTrue(c.ended)
        XCTAssertEqual(c.state, .idle)
        let u = Presentation.evaluate(rec(.working), now: 1001, alive: nil, lastWake: nil)
        XCTAssertEqual(u.state, .working, "unknown liveness is not treated as exit")
    }

    func testRetentionNeverRemovesActive() {
        for s in [SessionState.working, .waiting] {
            let e = Presentation.evaluate(rec(s, last: 0), now: 1e9, alive: true, lastWake: 1e9)
            XCTAssertFalse(Presentation.isRemovable(e, now: 1e9, retention: nil))
            XCTAssertFalse(Presentation.isRemovable(e, now: 1e9, retention: 1))
        }
        let done = eff(.complete)
        XCTAssertTrue(Presentation.isRemovable(done, now: 1001, retention: nil))
        XCTAssertFalse(Presentation.isRemovable(done, now: 1001, retention: 3600))
        XCTAssertTrue(Presentation.isRemovable(done, now: 1000 + 3601, retention: 3600))
        XCTAssertTrue(Presentation.isRemovable(eff(.error), now: 1001, retention: nil))
        // A live session in Unknown (never yet observed to finish) is kept.
        XCTAssertFalse(Presentation.isRemovable(eff(.unknown), now: 1001, retention: nil))
    }

    func testElapsedAndTimeText() {
        var r = rec(.working, last: 1000)
        r.turnStartedAt = 1000 - 754
        r.turnObservedFromStart = true
        XCTAssertEqual(Presentation.timeText(Presentation.evaluate(r, now: 1000, alive: nil, lastWake: nil), now: 1000), "12m 34s")
        r.turnObservedFromStart = false
        XCTAssertEqual(Presentation.timeText(Presentation.evaluate(r, now: 1000, alive: nil, lastWake: nil), now: 1000), "≥ 12m 34s")
        var c = rec(.complete, last: 1000)
        c.lastCompletedAt = 1000
        c.lastTurnDuration = 125
        c.lastTurnDurationExact = true
        XCTAssertEqual(Presentation.timeText(Presentation.evaluate(c, now: 1480, alive: nil, lastWake: nil), now: 1480), "8m ago · took 2m")
    }

    func testFormat() {
        XCTAssertEqual(Format.clock(5), "5s")
        XCTAssertEqual(Format.clock(754), "12m 34s")
        XCTAssertEqual(Format.clock(3900), "1h 05m")
        XCTAssertEqual(Format.clock(-4), "0s")
        XCTAssertEqual(Format.duration(59), "59s")
        XCTAssertEqual(Format.duration(3600), "1h")
        XCTAssertEqual(Format.duration(3 * 3600 + 300), "3h 5m")
        XCTAssertEqual(Format.duration(2 * 86400 + 4 * 3600), "2d 4h")
        XCTAssertEqual(Format.ago(3), "just now")
    }

    func testSortedPutsAttentionFirst() {
        let s = Presentation.sorted([eff(.complete), eff(.working), eff(.waiting)])
        XCTAssertEqual(s.map(\.state), [.waiting, .working, .complete])
    }

    func testDetails() {
        var r = rec(.waiting); r.reason = .permission
        XCTAssertEqual(Presentation.evaluate(r, now: 1001, alive: nil, lastWake: nil).detail, "Approval required")
        var e = rec(.error); e.reason = .apiError; e.errorCategory = "rate_limit"
        XCTAssertEqual(Presentation.evaluate(e, now: 1001, alive: nil, lastWake: nil).detail, "API error: rate_limit")
    }
}

import XCTest
@testable import ClaudeStatusCore

/// Replays hook event sequences recorded live from Claude Code Desktop 2.1.330 and CLI
/// 2.1.325 test sessions (Tests/Fixtures/recorded). Fixtures are sanitized: event names,
/// relative times, tool names, agent types, notification types, background task types and
/// statuses, and schedule offsets — no ids, paths, prompts or output. Each payload goes
/// through the real parser and state machine.
final class RecordedSequenceTests: XCTestCase {
    struct Step { let event: String; let label: String; let ofMainThread: Bool; let index: Int }

    static var fixtureDir: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/recorded")
    }

    /// Replay a fixture; returns the label after every event (and the events).
    func replay(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws -> [(event: [String: Any], view: EffectiveSession)] {
        let url = Self.fixtureDir.appendingPathComponent(name + ".json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any], file: file, line: line)
        let events = try XCTUnwrap(root["events"] as? [[String: Any]])
        let base = Date().timeIntervalSince1970.rounded() - 3600
        var record: SessionRecord? = StateMachine.reduce(nil, ev(.sessionStart, "rec", t: base - 10, source: "startup"))
        var out: [([String: Any], EffectiveSession)] = []
        for e in events {
            let t = base + (e["t"] as? Double ?? 0)
            var payload = e
            payload["session_id"] = "rec"
            payload["hook_event_name"] = e["event"]
            payload["t"] = nil; payload["event"] = nil
            if let crons = e["session_crons"] as? [[String: Any]] {
                payload["session_crons"] = crons.map { c -> [String: Any] in
                    let due = Date(timeIntervalSince1970: t + (c["due_in"] as? Double ?? 0))
                    let dc = Calendar.current.dateComponents([.minute, .hour, .day, .month], from: due)
                    return ["id": "c", "recurring": c["recurring"] as? Bool ?? false,
                            "schedule": "\(dc.minute!) \(dc.hour!) \(dc.day!) \(dc.month!) *"]
                }
            }
            let parsed = try HookEventParser.parse(JSONSerialization.data(withJSONObject: payload), timestamp: t)
            record = StateMachine.reduce(record, parsed)
            let v = Presentation.evaluate(record!, now: t + 0.5, alive: true, lastWake: nil)
            // Invariants for every recorded step.
            if let bg = record!.activeBackground, !bg.isEmpty {
                XCTAssertNotEqual(v.state, .complete, "\(name): Complete while background work was reported", file: file, line: line)
            }
            if record!.schedules.map({ $0.oneShot > 0 }) == true {
                XCTAssertNotEqual(v.state, .complete, "\(name): Complete while a wakeup was pending", file: file, line: line)
            }
            XCTAssertNotEqual(v.state, .error, "\(name): no recorded sequence contains a failure", file: file, line: line)
            out.append((e, v))
        }
        return out
    }

    /// Label after the n-th (1-based) main-thread occurrence of `event`.
    func label(_ steps: [(event: [String: Any], view: EffectiveSession)], after event: String, _ n: Int = 1) -> String? {
        var count = 0
        for s in steps where s.event["event"] as? String == event && s.event["agent_id"] == nil {
            count += 1
            if count == n { return s.view.label }
        }
        return nil
    }

    func final(_ steps: [(event: [String: Any], view: EffectiveSession)]) -> String { steps.last!.view.label }

    func testDesktopMultipleBackgroundTasksOneFailing() throws {
        let s = try replay("desktop-background-multi")
        XCTAssertEqual(label(s, after: "Stop", 1), "Working — Background")
        XCTAssertEqual(s.first { ($0.event["event"] as? String) == "Stop" }?.view.backgroundActive, 2)
        XCTAssertEqual(label(s, after: "UserPromptSubmit", 2), "Working — Continuing", "first task exited; Claude resumed")
        XCTAssertEqual(label(s, after: "Stop", 2), "Working — Background")
        XCTAssertEqual(final(s), "Complete")
    }

    func testDesktopStopDuringToolAndGenerationIsNeverComplete() throws {
        XCTAssertEqual(final(try replay("desktop-stop-during-tool")), "Unknown — Possibly interrupted")
        XCTAssertEqual(final(try replay("desktop-stop-during-generation")), "Unknown — Possibly interrupted")
    }

    func testDesktopBackgroundCancelInSameTurn() throws {
        XCTAssertEqual(final(try replay("desktop-background-cancel-same-turn")), "Complete")
    }

    func testDesktopBackgroundSubagent() throws {
        let s = try replay("desktop-background-subagent")
        XCTAssertEqual(label(s, after: "Stop", 1), "Working — Background")
        // The subagent's own SubagentStop never completes the parent.
        let subStop = s.first { ($0.event["event"] as? String) == "SubagentStop" && ($0.event["agent_type"] as? String) == "general-purpose" }
        XCTAssertEqual(subStop?.view.state, .working)
        XCTAssertEqual(final(s), "Complete")
    }

    func testDesktopMonitor() throws {
        let s = try replay("desktop-monitor")
        XCTAssertEqual(label(s, after: "Stop", 1), "Working — Background")
        XCTAssertTrue(s.first { ($0.event["event"] as? String) == "Stop" }!.view.detail.contains("monitor"))
        XCTAssertEqual(final(s), "Complete")
    }

    func testDesktopScheduledWakeup() throws {
        let s = try replay("desktop-scheduled-wakeup")
        let scheduled = s.first { ($0.event["event"] as? String) == "Stop" }!.view
        XCTAssertEqual(scheduled.label, "Continuation scheduled")
        XCTAssertNotNil(scheduled.wakeupDueAt)
        XCTAssertEqual(label(s, after: "UserPromptSubmit", 2), "Working — Continuing", "the wakeup fired")
        XCTAssertEqual(final(s), "Complete")
    }

    func testDesktopPermissionGrantedWhileBackgroundRuns() throws {
        let s = try replay("desktop-permission-granted-with-background")
        XCTAssertEqual(label(s, after: "PermissionRequest"), "Waiting")
        XCTAssertEqual(s.first { ($0.event["notification_type"] as? String) == "permission_prompt" }?.view.state, .waiting)
        XCTAssertEqual(final(s), "Complete")
    }

    func testCliPermissionDeniedWithEscStaysWaiting() throws {
        let s = try replay("cli-permission-denied-with-esc")
        XCTAssertEqual(final(s), "Waiting", "no event follows an Esc denial; the session awaits the user")
    }

    func testCliQuestionAnsweredAndCancelled() throws {
        let a = try replay("cli-question-answered")
        XCTAssertEqual(a.first { ($0.event["event"] as? String) == "PermissionRequest" }?.view.detail, "Question for you")
        XCTAssertEqual(final(a), "Complete")
        let c = try replay("cli-question-cancelled-with-esc")
        XCTAssertEqual(c.last!.view.detail, "Question for you")
    }

    func testCliBackgroundMultiCancelAndSubagents() throws {
        let m = try replay("cli-background-multi")
        XCTAssertEqual(label(m, after: "Stop", 1), "Working — Background")
        XCTAssertEqual(final(m), "Complete")
        let c = try replay("cli-background-cancel-next-turn")
        XCTAssertEqual(label(c, after: "Stop", 1), "Working — Background")
        XCTAssertEqual(final(c), "Complete")
        let sa = try replay("cli-background-subagents")
        XCTAssertEqual(label(sa, after: "Stop", 1), "Working — Background")
        XCTAssertEqual(final(sa), "Complete")
    }

    func testCliIdlePromptAfterStopKeepsComplete() throws {
        XCTAssertEqual(final(try replay("cli-idle-prompt-after-stop")), "Complete")
    }

    func testEveryFixtureIsSanitized() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.fixtureDir.path).filter { $0.hasSuffix(".json") }
        XCTAssertGreaterThanOrEqual(files.count, 15)
        let allowed: Set<String> = ["t", "event", "agent_id", "agent_type", "tool_name", "tool_use_id", "notification_type",
                                    "is_interrupt", "error", "source", "reason", "background_tasks", "session_crons"]
        for f in files {
            let text = try String(contentsOf: Self.fixtureDir.appendingPathComponent(f), encoding: .utf8)
            for leak in ["/Users", "\"prompt\"", "command", "description", "session_id", "transcript"] {
                XCTAssertFalse(text.contains(leak), "\(f) contains \(leak)")
            }
            let root = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
            for e in root["events"] as! [[String: Any]] { XCTAssertTrue(Set(e.keys).isSubset(of: allowed), "\(f): \(e.keys)") }
        }
    }
}

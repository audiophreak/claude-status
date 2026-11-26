import XCTest
@testable import ClaudeStatusCore

final class HookEventParserTests: XCTestCase {
    func testParsesDocumentedFieldsAndDropsSensitiveOnes() throws {
        let d = json([
            "session_id": "0b9c1d2e-aaaa-bbbb-cccc-1234567890ab",
            "hook_event_name": "PreToolUse",
            "cwd": "/Users/x/project",
            "transcript_path": "/Users/x/.claude/projects/p/t.jsonl",
            "prompt": "my secret prompt",
            "tool_name": "Bash",
            "tool_use_id": "toolu_01ABC",
            "tool_input": ["command": "echo secret-token"],
            "agent_id": "agent-7",
            "prompt_id": "p-1",
        ])
        let e = try HookEventParser.parse(d, timestamp: 10)
        XCTAssertEqual(e.name, .preToolUse)
        XCTAssertEqual(e.sessionId, "0b9c1d2e-aaaa-bbbb-cccc-1234567890ab")
        XCTAssertEqual(e.cwd, "/Users/x/project")
        XCTAssertEqual(e.toolName, "Bash")
        XCTAssertEqual(e.toolUseId, "toolu_01ABC")
        XCTAssertEqual(e.agentId, "agent-7")
        XCTAssertTrue(e.isSubagent)
        // The model type has no place to hold prompt / tool input / transcript path.
        let mirror = Mirror(reflecting: e).children.map { "\($0.value)" }.joined()
        XCTAssertFalse(mirror.contains("secret"))
        XCTAssertFalse(mirror.contains("transcript"))
    }

    func testStopFields() throws {
        let d = json(["session_id": "s", "hook_event_name": "Stop", "stop_hook_active": true,
                      "background_tasks": [["type": "shell"], ["type": "subagent"]], "last_assistant_message": "hi"])
        let e = try HookEventParser.parse(d, timestamp: 1)
        XCTAssertTrue(e.stopHookActive)
        XCTAssertEqual(e.backgroundTaskCount, 2)
    }

    func testStopFailureAndNotificationFields() throws {
        var e = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "StopFailure", "error": "rate_limit", "error_details": "x"]), timestamp: 1)
        XCTAssertEqual(e.errorCategory, "rate_limit")
        e = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "Notification", "notification_type": "permission_prompt", "message": "m"]), timestamp: 1)
        XCTAssertEqual(e.notificationType, "permission_prompt")
        e = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "PostToolUseFailure", "is_interrupt": true]), timestamp: 1)
        XCTAssertTrue(e.isInterrupt)
    }

    func testRejectsMalformedInput() {
        XCTAssertThrowsError(try HookEventParser.parse(Data(), timestamp: 0)) { XCTAssertEqual($0 as? HookEventParseError, .empty) }
        XCTAssertThrowsError(try HookEventParser.parse(Data("not json".utf8), timestamp: 0)) { XCTAssertEqual($0 as? HookEventParseError, .malformedJSON) }
        XCTAssertThrowsError(try HookEventParser.parse(Data("[1,2]".utf8), timestamp: 0)) { XCTAssertEqual($0 as? HookEventParseError, .notAnObject) }
        XCTAssertThrowsError(try HookEventParser.parse(json(["hook_event_name": "Stop"]), timestamp: 0)) { XCTAssertEqual($0 as? HookEventParseError, .missingSessionId) }
        XCTAssertThrowsError(try HookEventParser.parse(json(["session_id": "s"]), timestamp: 0)) { XCTAssertEqual($0 as? HookEventParseError, .missingEventName) }
        XCTAssertThrowsError(try HookEventParser.parse(json(["session_id": 42, "hook_event_name": "Stop"]), timestamp: 0)) { XCTAssertEqual($0 as? HookEventParseError, .invalidSessionId) }
        XCTAssertThrowsError(try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "Stop; rm -rf"]), timestamp: 0)) { XCTAssertEqual($0 as? HookEventParseError, .invalidEventName) }
    }

    func testRejectsPathTraversalSessionIds() {
        for bad in ["../../etc/passwd", "a/b", "", ".hidden", "x y", String(repeating: "a", count: 200), "sess\u{0}ion", "é"] {
            XCTAssertThrowsError(try HookEventParser.parse(json(["session_id": bad, "hook_event_name": "Stop"]), timestamp: 0), bad)
        }
    }

    func testInvalidOptionalFieldsAreDroppedNotFatal() throws {
        let e = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "PreToolUse", "cwd": "relative/path",
                                                "tool_name": "bad name with spaces", "agent_id": 5]), timestamp: 0)
        XCTAssertNil(e.cwd)
        XCTAssertNil(e.toolName)
        XCTAssertNil(e.agentId)
        let e2 = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "Stop", "cwd": "/a/\u{1b}[31mb"]), timestamp: 0)
        XCTAssertNil(e2.cwd)
    }

    func testUnknownEventIsAcceptedWithoutName() throws {
        let e = try HookEventParser.parse(json(["session_id": "s", "hook_event_name": "PostToolBatch"]), timestamp: 0)
        XCTAssertNil(e.name)
        XCTAssertEqual(e.rawName, "PostToolBatch")
    }

    func testOversizedPayloadUsesPrefixScan() throws {
        let big = String(repeating: "x", count: HookEventParser.maxParsedBytes + 10)
        let text = "{\"session_id\": \"big-1\", \"hook_event_name\": \"PostToolUse\", \"cwd\": \"/tmp/p\", \"tool_name\": \"Read\", \"tool_use_id\": \"t9\", \"tool_response\": \"\(big)\"}"
        let e = try HookEventParser.parse(Data(text.utf8), timestamp: 3)
        XCTAssertEqual(e.name, .postToolUse)
        XCTAssertEqual(e.sessionId, "big-1")
        XCTAssertEqual(e.toolUseId, "t9")
        XCTAssertEqual(e.cwd, "/tmp/p")
        // Truncated (not fully read) payload also goes through the scan.
        let e2 = try HookEventParser.parse(Data(text.utf8.prefix(1000)), timestamp: 3, truncated: true)
        XCTAssertEqual(e2.sessionId, "big-1")
    }

    func testValidateHelpers() {
        XCTAssertTrue(Validate.sessionId("0b9c1d2e-aaaa_BBBB"))
        XCTAssertTrue(Validate.token("mcp__github__create_issue"))
        XCTAssertFalse(Validate.token("a b"))
        XCTAssertTrue(Validate.absolutePath("/Users/me/My Project"))
        XCTAssertFalse(Validate.absolutePath("~/x"))
        XCTAssertFalse(Validate.absolutePath("/a\nb"))
    }
}

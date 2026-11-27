import ClaudeStatusCore
import Foundation

/// End-to-end check of the installed hook executable against an isolated temporary store:
/// event emission (stdin JSON) -> hook process -> ingestion -> state derivation.
/// The real store, settings and Claude Code are never touched.
enum SelfTest {
    static func run(hook: URL) -> Bool {
        guard FileManager.default.isExecutableFile(atPath: hook.path) else {
            print("FAIL  hook executable not found: \(hook.path)")
            return false
        }
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let dir = base.appendingPathComponent("claude-status-selftest-\(UUID().uuidString)", isDirectory: true)
        defer {
            if dir.path.hasPrefix(NSTemporaryDirectory()), dir.lastPathComponent.hasPrefix("claude-status-selftest-") {
                try? FileManager.default.removeItem(at: dir)
            }
        }
        let paths = StatusPaths(root: dir.appendingPathComponent("home"))
        let store = SessionStore(paths: paths)
        let sid = "selftest-\(UUID().uuidString.prefix(8))"
        let secret = "SELFTEST-PRIVATE-\(UUID().uuidString)"
        var pass = 0, fail = 0
        func check(_ name: String, _ ok: Bool) {
            if ok { pass += 1; print("PASS  \(name)") } else { fail += 1; print("FAIL  \(name)") }
        }
        func send(_ obj: [String: Any]) -> (status: Int32, output: Data) {
            var o = obj
            o["session_id"] = sid
            o["cwd"] = dir.path
            let p = Process()
            p.executableURL = hook
            p.environment = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin", "CLAUDE_STATUS_HOME": paths.root.path]
            let input = Pipe(), output = Pipe()
            p.standardInput = input
            p.standardOutput = output
            p.standardError = output
            do { try p.run() } catch { return (-1, Data()) }
            input.fileHandleForWriting.write((try? JSONSerialization.data(withJSONObject: o)) ?? Data())
            try? input.fileHandleForWriting.close()
            let out = output.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, out)
        }
        func state() -> EffectiveSession? {
            guard case .record(let r) = store.load(sid) else { return nil }
            return Presentation.evaluate(r, now: Date().timeIntervalSince1970, alive: nil, lastWake: nil)
        }
        let shell: [String: Any] = ["id": "bg-1", "type": "shell", "status": "running", "command": secret, "description": secret]

        var r = send(["hook_event_name": "UserPromptSubmit", "prompt": secret])
        check("hook exits 0 and prints nothing", r.status == 0 && r.output.isEmpty)
        check("prompt submit -> Working (foreground)", state().map { $0.state == .working && $0.activity == .foreground } ?? false)

        r = send(["hook_event_name": "Stop", "last_assistant_message": secret, "background_tasks": [shell], "session_crons": []])
        check("Stop with a running background task -> Working — Background",
              state().map { $0.state == .working && $0.activity == .background && $0.backgroundActive == 1 } ?? false)

        r = send(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "t1", "tool_input": ["command": secret]])
        check("activity after background work -> Working — Continuing",
              state().map { $0.state == .working && $0.activity == .foreground && $0.record.reason == .autoContinued } ?? false)
        _ = send(["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "t1", "tool_response": secret])

        r = send(["hook_event_name": "Stop", "background_tasks": [], "session_crons": []])
        check("Stop with no background work -> Complete", state()?.state == .complete)

        _ = send(["hook_event_name": "UserPromptSubmit", "prompt": secret])
        r = send(["hook_event_name": "Stop"])
        check("Stop without background report -> Unknown (never assumed complete)", state()?.state == .unknown)

        // Approval request: Waiting until that tool call is answered.
        _ = send(["hook_event_name": "UserPromptSubmit", "prompt": secret])
        _ = send(["hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_use_id": "t2", "tool_input": ["command": secret]])
        _ = send(["hook_event_name": "PermissionRequest", "tool_name": "Bash", "tool_input": ["command": secret]])
        check("permission request -> Waiting (approval required)", state().map { $0.state == .waiting && $0.record.reason == .permission } ?? false)
        _ = send(["hook_event_name": "PostToolUse", "tool_name": "Bash", "tool_use_id": "t2", "tool_response": secret])
        check("approved tool finishes -> Working", state()?.state == .working)

        // Interrupt evidence: the internal prompt-suggestion agent's SubagentStop mid-turn.
        _ = send(["hook_event_name": "SubagentStop", "agent_id": "internal-1", "agent_type": "", "background_tasks": [],
                  "session_crons": [], "last_assistant_message": secret])
        check("turn ended without Stop -> Unknown — Possibly interrupted (never Complete)",
              state().map { $0.state == .unknown && $0.label == "Unknown — Possibly interrupted" } ?? false)

        // Scheduled one-shot wakeup with a due time (only the schedule expression is read).
        let due = Date().addingTimeInterval(900)
        let c = Calendar.current.dateComponents([.minute, .hour, .day, .month], from: due)
        _ = send(["hook_event_name": "UserPromptSubmit", "prompt": secret])
        _ = send(["hook_event_name": "Stop", "background_tasks": [],
                  "session_crons": [["id": "w1", "schedule": "\(c.minute!) \(c.hour!) \(c.day!) \(c.month!) *", "recurring": false, "prompt": secret]]])
        check("one-shot wakeup -> Continuation scheduled with its due time",
              state().map { $0.label == "Continuation scheduled" && $0.wakeupDueAt != nil } ?? false)

        let file = paths.sessionFile(sid)
        let bytes = (try? Data(contentsOf: file)) ?? Data()
        check("record stores no prompt, message, command or description",
              !bytes.isEmpty && bytes.range(of: Data(secret.utf8)) == nil)
        let log = (try? Data(contentsOf: paths.hookLog)) ?? Data()
        check("hook log records events without content", !log.isEmpty && log.range(of: Data(secret.utf8)) == nil)

        print("Self-test: \(pass) passed, \(fail) failed (isolated store, removed afterwards)")
        return fail == 0
    }
}

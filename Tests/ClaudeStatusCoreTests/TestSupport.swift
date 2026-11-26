import Foundation
import XCTest
@testable import ClaudeStatusCore

/// Unique temporary directory per test; removed (by exact path, recursively only inside the
/// system temporary directory) in tearDown.
class TempDirTestCase: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        tmp = base.appendingPathComponent("claude-status-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        guard let tmp, tmp.path.hasPrefix(NSTemporaryDirectory()), tmp.lastPathComponent.hasPrefix("claude-status-tests-") else { return }
        try? FileManager.default.removeItem(at: tmp)
    }

    var paths: StatusPaths { StatusPaths(root: tmp.appendingPathComponent("home")) }

    func write(_ s: String, to name: String) -> URL {
        let u = tmp.appendingPathComponent(name)
        try! Data(s.utf8).write(to: u)
        return u
    }
}

func ev(_ name: HookEventName, _ sid: String = "s1", t: Double, agent: String? = nil, tool: String? = nil,
        toolUseId: String? = nil, source: String? = nil, notification: String? = nil, error: String? = nil,
        interrupt: Bool = false, cwd: String? = nil) -> HookEvent {
    HookEvent(name: name, rawName: name.rawValue, sessionId: sid, timestamp: t, cwd: cwd, agentId: agent,
              toolName: tool, toolUseId: toolUseId, source: source, notificationType: notification,
              errorCategory: error, isInterrupt: interrupt)
}

func apply(_ events: [HookEvent], from start: SessionRecord? = nil) -> SessionRecord {
    var r = start
    for e in events { r = StateMachine.reduce(r, e) }
    return r!
}

func json(_ obj: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: obj)
}

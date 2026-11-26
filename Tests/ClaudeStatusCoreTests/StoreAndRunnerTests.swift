import Darwin
import XCTest
@testable import ClaudeStatusCore

final class StoreAndRunnerTests: TempDirTestCase {
    func testSaveLoadRoundTripWithUserOnlyPermissions() throws {
        let store = SessionStore(paths: paths)
        try paths.ensureDirectories()
        var r = SessionRecord(sessionId: "abc", timestamp: 5)
        r.state = .working
        try store.save(r)
        XCTAssertEqual(store.load("abc"), .record(r))
        var st = stat()
        XCTAssertEqual(stat(paths.sessionFile("abc").path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o600)
        XCTAssertEqual(stat(paths.sessionsDir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertEqual(store.load("missing"), .missing)
    }

    func testCorruptRecordsAreDetectedAndRecovered() throws {
        let store = SessionStore(paths: paths)
        try paths.ensureDirectories()
        try Data("{not json".utf8).write(to: paths.sessionFile("bad"))
        XCTAssertEqual(store.load("bad"), .corrupt)
        // Wrong embedded id (renamed file) is not trusted.
        var r = SessionRecord(sessionId: "other", timestamp: 1)
        r.state = .complete
        try JSONEncoder().encode(r).write(to: paths.sessionFile("renamed"))
        XCTAssertEqual(store.load("renamed"), .corrupt)
        // Oversized.
        try Data(repeating: 0x20, count: SessionStore.maxRecordBytes + 10).write(to: paths.sessionFile("huge"))
        XCTAssertEqual(store.load("huge"), .corrupt)
        let (records, corrupt) = store.loadAll()
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(Set(corrupt), ["bad.json", "renamed.json", "huge.json"])
        // A hook event for a corrupt session replaces the record cleanly.
        let out = HookRunner.process(payload: json(["session_id": "bad", "hook_event_name": "UserPromptSubmit"]),
                                     truncated: false, timestamp: 10, context: HookContext(), paths: paths)
        XCTAssertTrue(out.accepted)
        XCTAssertEqual(out.detail, "ok-corrupt-replaced")
        guard case .record(let fixed) = store.load("bad") else { return XCTFail() }
        XCTAssertEqual(fixed.state, .working)
    }

    func testLoadAllIgnoresTempAndForeignFiles() throws {
        let store = SessionStore(paths: paths)
        try paths.ensureDirectories()
        try store.save(SessionRecord(sessionId: "good", timestamp: 1))
        try Data("x".utf8).write(to: paths.sessionsDir.appendingPathComponent(".good.json.tmp.1.2"))
        try Data("x".utf8).write(to: paths.sessionsDir.appendingPathComponent("notes.txt"))
        let (records, corrupt) = store.loadAll()
        XCTAssertEqual(records.map(\.sessionId), ["good"])
        XCTAssertTrue(corrupt.isEmpty)
    }

    func testRejectedInputWritesNoSessionFile() {
        let out = HookRunner.process(payload: Data("{\"session_id\":\"../evil\",\"hook_event_name\":\"Stop\"}".utf8),
                                     truncated: false, timestamp: 1, context: HookContext(), paths: paths)
        XCTAssertFalse(out.accepted)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.sessionsDir.path))
    }

    func testConcurrentHookProcessesSerialiseCorrectly() {
        // 400 events across 4 sessions applied concurrently: no lost updates.
        DispatchQueue.concurrentPerform(iterations: 400) { i in
            let sid = "sess\(i % 4)"
            _ = HookRunner.process(payload: json(["session_id": sid, "hook_event_name": "PostToolBatch"]),
                                   truncated: false, timestamp: Double(i), context: HookContext(), paths: paths)
        }
        let (records, corrupt) = SessionStore(paths: paths).loadAll()
        XCTAssertTrue(corrupt.isEmpty)
        XCTAssertEqual(records.count, 4)
        // Out-of-order arrivals are ignored, but every event was either applied or counted.
        for r in records { XCTAssertEqual(r.eventCount + r.ignoredOutOfOrder, 100, r.sessionId) }
    }

    func testLockTimeoutFailsOpen() throws {
        let store = SessionStore(paths: paths)
        try paths.ensureDirectories()
        let fd = open(paths.lockFile.path, O_RDWR | O_CREAT, 0o600)
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        let start = Date()
        XCTAssertThrowsError(try store.withLock(timeout: 0.2) { () }) { XCTAssertEqual($0 as? StoreError, .lockTimeout) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testReadBoundedDrainsAndTruncates() throws {
        var fds: [Int32] = [0, 0]
        XCTAssertEqual(pipe(&fds), 0)
        let total = 3 * 1024 * 1024
        let writer = Thread {
            let chunk = [UInt8](repeating: 0x61, count: 65536)
            var sent = 0
            while sent < total { sent += chunk.withUnsafeBytes { Darwin.write(fds[1], $0.baseAddress, $0.count) } }
            close(fds[1])
        }
        writer.start()
        let (data, truncated) = HookRunner.readBounded(fd: fds[0], limit: 1024 * 1024)
        close(fds[0])
        XCTAssertEqual(data.count, 1024 * 1024)
        XCTAssertTrue(truncated)
    }

    func testClientTypeDetection() {
        XCTAssertEqual(HookRunner.clientType(env: ["CLAUDE_CODE_ENTRYPOINT": "claude-desktop"]).0, .desktop)
        XCTAssertEqual(HookRunner.clientType(env: ["CLAUDE_CODE_DESKTOP_APP_VERSION": "1.0"]).0, .desktop)
        XCTAssertEqual(HookRunner.clientType(env: ["CLAUDE_CODE_ENTRYPOINT": "cli"]).0, .cli)
        XCTAssertEqual(HookRunner.clientType(env: ["CLAUDE_CODE_ENTRYPOINT": "sdk-cli"]).0, .cli)
        XCTAssertEqual(HookRunner.clientType(env: ["CLAUDE_CODE_ENTRYPOINT": "sdk-ts"]).0, .unknown)
        XCTAssertEqual(HookRunner.clientType(env: [:]).0, .unknown)
        XCTAssertNil(HookRunner.clientType(env: ["CLAUDE_CODE_ENTRYPOINT": "bad value; rm"]).1)
    }

    func testProcessLivenessHelpers() {
        let me = ProcessInspector.info(getpid())
        XCTAssertNotNil(me)
        XCTAssertTrue(ProcessInspector.isAlive(pid: getpid(), startTime: me?.startTime))
        XCTAssertFalse(ProcessInspector.isAlive(pid: getpid(), startTime: (me?.startTime ?? 0) - 1000), "PID reuse guard")
        XCTAssertFalse(ProcessInspector.isAlive(pid: 999_999, startTime: nil))
        XCTAssertNil(ProcessInspector.findClaudeAncestor(env: ["CLAUDE_PID": "\(getpid())"], startingAt: 1))
    }

    func testRetentionCleanupScenario() throws {
        // Records written by the hook are evaluated and selected for cleanup by the app logic.
        let store = SessionStore(paths: paths)
        for (sid, name) in [("done", "Stop"), ("busy", "UserPromptSubmit")] {
            _ = HookRunner.process(payload: json(["session_id": sid, "hook_event_name": name, "background_tasks": []]), truncated: false,
                                   timestamp: 100, context: HookContext(), paths: paths)
        }
        let eff = store.loadAll().records.map { Presentation.evaluate($0, now: 100 + 90_000, alive: nil, lastWake: 100 + 89_000) }
        let removable = eff.filter { Presentation.isRemovable($0, now: 100 + 90_000, retention: 86_400) }.map(\.id)
        XCTAssertEqual(removable, ["done"])
    }
}

final class ProjectInfoTests: TempDirTestCase {
    func testRepoWorktreeAndPlainDirectory() throws {
        let fm = FileManager.default
        let repo = tmp.appendingPathComponent("my-repo")
        try fm.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try fm.createDirectory(at: repo.appendingPathComponent("src/deep"), withIntermediateDirectories: true)
        XCTAssertEqual(ProjectInfo.detect(from: repo.appendingPathComponent("src/deep").path)?.repoName, "my-repo")

        let wt = tmp.appendingPathComponent("wt-checkout")
        try fm.createDirectory(at: wt, withIntermediateDirectories: true)
        try Data("gitdir: \(repo.path)/.git/worktrees/feature-x\n".utf8).write(to: wt.appendingPathComponent(".git"))
        let info = ProjectInfo.detect(from: wt.path)
        XCTAssertEqual(info?.repoName, "my-repo")
        XCTAssertEqual(info?.worktreeName, "feature-x")

        let plain = tmp.appendingPathComponent("plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: true)
        // tmp is not inside a repository on a normal system.
        XCTAssertNil(ProjectInfo.detect(from: plain.path)?.worktreeName)
        XCTAssertNil(ProjectInfo.detect(from: "relative"))
    }

    func testWorktreeSessionsStayDistinct() {
        var store: [String: SessionRecord] = [:]
        for (sid, cwd) in [("main-s", "/r/repo"), ("wt-s", "/r/repo/.claude/worktrees/a")] {
            store[sid] = StateMachine.reduce(nil, ev(.userPromptSubmit, sid, t: 1, cwd: cwd)) { c in
                ProjectInfo(repoRoot: c, repoName: "repo", worktreeName: c.contains("worktrees") ? "a" : nil)
            }
        }
        XCTAssertEqual(store.count, 2)
        XCTAssertEqual(store["wt-s"]?.worktreeName, "a")
        XCTAssertNil(store["main-s"]?.worktreeName)
    }
}

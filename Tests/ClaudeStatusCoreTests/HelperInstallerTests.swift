import Darwin
import XCTest
@testable import ClaudeStatusCore

final class HelperInstallerTests: TempDirTestCase {
    func makeSource(_ hook: String = "#!/bin/sh\nexit 0\n", _ ctl: String = "#!/bin/sh\necho ctl\n") throws -> URL {
        let src = tmp.appendingPathComponent("Helpers")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        for (n, body) in [("claude-status-hook", hook), ("claude-status-ctl", ctl)] {
            let u = src.appendingPathComponent(n)
            try Data(body.utf8).write(to: u)
            chmod(u.path, 0o755)
        }
        return src
    }

    func testInstallsWithModesAndIsIdempotent() throws {
        let src = try makeSource()
        XCTAssertEqual(try HelperInstaller.install(from: src, paths: paths), .installed(["claude-status-hook", "claude-status-ctl"]))
        var st = stat()
        XCTAssertEqual(stat(paths.hookExecutable.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o755)
        XCTAssertEqual(stat(paths.binDir.path, &st), 0)
        XCTAssertEqual(st.st_mode & 0o777, 0o700)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: paths.ctlExecutable.path))
        XCTAssertEqual(try HelperInstaller.install(from: src, paths: paths), .upToDate)
    }

    func testUpdatesChangedHelpers() throws {
        _ = try HelperInstaller.install(from: try makeSource(), paths: paths)
        let newer = tmp.appendingPathComponent("v2"); try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
        for n in HelperInstaller.helperNames { try Data("v2 \(n)".utf8).write(to: newer.appendingPathComponent(n)) }
        XCTAssertFalse(HelperInstaller.isUpToDate(from: newer, paths: paths))
        XCTAssertEqual(try HelperInstaller.install(from: newer, paths: paths), .installed(HelperInstaller.helperNames))
        XCTAssertEqual(String(decoding: try Data(contentsOf: paths.hookExecutable), as: UTF8.self), "v2 claude-status-hook")
    }

    func testRejectsMissingSymlinkedOrEmptySources() throws {
        let empty = tmp.appendingPathComponent("empty"); try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        XCTAssertThrowsError(try HelperInstaller.install(from: empty, paths: paths))
        let linked = tmp.appendingPathComponent("linked"); try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
        let real = try makeSource()
        for n in HelperInstaller.helperNames {
            try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent(n), withDestinationURL: real.appendingPathComponent(n))
        }
        XCTAssertThrowsError(try HelperInstaller.install(from: linked, paths: paths)) {
            guard case HelperInstaller.InstallError.invalidSource = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.hookExecutable.path), "nothing installed on failure")
    }
}

final class ClaudePathsTests: XCTestCase {
    func testSettingsResolution() {
        XCTAssertEqual(ClaudePaths.userSettings(env: ["HOME": "/Users/x"]).path, "/Users/x/.claude/settings.json")
        XCTAssertEqual(ClaudePaths.userSettings(env: ["HOME": "/Users/x", "CLAUDE_CONFIG_DIR": "/opt/cfg"]).path, "/opt/cfg/settings.json")
        XCTAssertEqual(ClaudePaths.userSettings(env: ["HOME": "/Users/x", "CLAUDE_CONFIG_DIR": "relative"]).path, "/Users/x/.claude/settings.json")
        XCTAssertEqual(ClaudePaths.userSettings(env: [:]).path,
                       FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json").path)
    }
}

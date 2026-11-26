import Foundation

/// Filesystem layout for Claude Status runtime state.
///
/// Default root: `~/Library/Application Support/ClaudeStatus`. Tests (and only tests)
/// override it with the `CLAUDE_STATUS_HOME` environment variable or an explicit URL.
public struct StatusPaths: Sendable, Equatable {
    public let root: URL

    public init(root: URL) {
        self.root = root.standardizedFileURL
    }

    public static func defaultRoot(home: URL = ClaudePaths.home()) -> URL {
        home.appendingPathComponent("Library/Application Support/ClaudeStatus", isDirectory: true)
    }

    /// Resolve from environment. `CLAUDE_STATUS_HOME` must be an absolute path to be honoured.
    public static func fromEnvironment(_ env: [String: String] = ProcessInfo.processInfo.environment) -> StatusPaths {
        if let override = env["CLAUDE_STATUS_HOME"], override.hasPrefix("/"), !override.contains("\0") {
            return StatusPaths(root: URL(fileURLWithPath: override, isDirectory: true))
        }
        return StatusPaths(root: defaultRoot())
    }

    public var sessionsDir: URL { root.appendingPathComponent("sessions", isDirectory: true) }
    public var lockFile: URL { sessionsDir.appendingPathComponent(".store.lock") }
    public var logsDir: URL { root.appendingPathComponent("logs", isDirectory: true) }
    public var hookLog: URL { logsDir.appendingPathComponent("hook.log") }
    public var binDir: URL { root.appendingPathComponent("bin", isDirectory: true) }
    public var hookExecutable: URL { binDir.appendingPathComponent("claude-status-hook") }
    public var ctlExecutable: URL { binDir.appendingPathComponent("claude-status-ctl") }
    public var backupsDir: URL { root.appendingPathComponent("backups", isDirectory: true) }
    public var installManifest: URL { root.appendingPathComponent("install-manifest.json") }

    public func sessionFile(_ sessionId: String) -> URL {
        sessionsDir.appendingPathComponent("\(sessionId).json")
    }

    /// Create the directory tree with user-only permissions (0700).
    public func ensureDirectories() throws {
        let fm = FileManager.default
        for dir in [root, sessionsDir, logsDir] {
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                       attributes: [.posixPermissions: 0o700])
            }
        }
    }
}

public enum ClaudePaths {
    /// User-scope Claude Code settings file, resolved like Claude Code resolves it:
    /// `$CLAUDE_CONFIG_DIR/settings.json` when that variable is set, else `$HOME/.claude/settings.json`.
    public static func userSettings(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let dir = env["CLAUDE_CONFIG_DIR"], Validate.absolutePath(dir) {
            return URL(fileURLWithPath: dir, isDirectory: true).appendingPathComponent("settings.json")
        }
        return home(env: env).appendingPathComponent(".claude/settings.json")
    }

    /// `$HOME` when it is an absolute path, otherwise the account's home directory.
    public static func home(env: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let h = env["HOME"], Validate.absolutePath(h) { return URL(fileURLWithPath: h, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}

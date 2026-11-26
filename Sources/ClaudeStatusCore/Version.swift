import Foundation

public enum ClaudeStatusVersion {
    /// Kept in sync with the repository `VERSION` file by `scripts/build.sh` checks.
    public static let current = "1.0.0"
    public static let bundleIdentifier = "io.github.audiophreak.ClaudeStatus"
    /// Marker used to recognise Claude Status hook entries in settings.json.
    public static let hookMarker = "claude-status-hook"
}

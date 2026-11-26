// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "claude-status",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeStatus", targets: ["ClaudeStatusApp"]),
        .executable(name: "claude-status-hook", targets: ["ClaudeStatusHook"]),
        .executable(name: "claude-status-ctl", targets: ["ClaudeStatusCtl"]),
    ],
    targets: [
        // Pure logic shared by every executable: event parsing, state machine,
        // session store, settings.json editing, diagnostics. No UI.
        .target(name: "ClaudeStatusCore"),
        // Invoked by Claude Code for each lifecycle event. Always exits 0, prints nothing.
        .executableTarget(name: "ClaudeStatusHook", dependencies: ["ClaudeStatusCore"]),
        // Install/uninstall/verify hooks, diagnostics, session listing.
        .executableTarget(name: "ClaudeStatusCtl", dependencies: ["ClaudeStatusCore"]),
        // SwiftUI menu bar application.
        .executableTarget(name: "ClaudeStatusApp", dependencies: ["ClaudeStatusCore"]),
        .testTarget(name: "ClaudeStatusCoreTests", dependencies: ["ClaudeStatusCore"]),
    ],
    swiftLanguageModes: [.v5]
)

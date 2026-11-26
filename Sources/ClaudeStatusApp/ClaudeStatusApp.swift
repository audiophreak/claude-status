import AppKit
import ClaudeStatusCore
import ServiceManagement
import SwiftUI

@main
struct ClaudeStatusApp: App {
    @StateObject private var model: AppModel

    init() {
        let args = CommandLine.arguments
        // Used by scripts/uninstall.sh: SMAppService.mainApp can only be changed by the app itself.
        if args.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            exit(0)
        }
        if let i = args.firstIndex(of: "--render-snapshots"), i + 1 < args.count {
            // Render after the application has finished launching, then quit.
            let dir = URL(fileURLWithPath: args[i + 1])
            _model = StateObject(wrappedValue: AppModel())
            DispatchQueue.main.async {
                MainActor.assumeIsolated { Snapshots.render(to: dir) }
                exit(0)
            }
            return
        }
        // Non-interactive equivalents of the in-app "Set Up Claude Code Hooks…" and
        // "Remove Hooks…" buttons (same code path, no dialogs). Used by tests and scripts.
        if args.contains("--setup-hooks") || args.contains("--remove-hooks") {
            let setup = args.contains("--setup-hooks")
            let result: (ok: Bool, message: String) = MainActor.assumeIsolated {
                let m = AppModel()
                m.refreshHealth()
                return setup ? m.setupIntegration() : m.removeIntegration()
            }
            print(result.message)
            exit(result.ok ? 0 : 1)
        }
        if args.contains("--register-login-item") {
            try? SMAppService.mainApp.register()
        }
        // Single instance (an isolated test instance with its own state root is allowed).
        let isolated = ProcessInfo.processInfo.environment["CLAUDE_STATUS_HOME"] != nil
        let others = isolated ? [] : NSRunningApplication.runningApplications(withBundleIdentifier: ClaudeStatusVersion.bundleIdentifier)
            .filter { $0.processIdentifier != getpid() }
        if !others.isEmpty { exit(0) }

        let m = AppModel()
        _model = StateObject(wrappedValue: m)
        DispatchQueue.main.async { m.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            DashboardView(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Claude Status Preferences", id: "preferences") {
            PreferencesView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

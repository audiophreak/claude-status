import ClaudeStatusCore
import ServiceManagement
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var model: AppModel
    @AppStorage(PrefKey.showCount) private var showCount = true
    @AppStorage(PrefKey.showElapsed) private var showElapsed = false
    @AppStorage(PrefKey.showDirectories) private var showDirectories = false
    @AppStorage(PrefKey.retentionHours) private var retentionHours = 24.0
    @AppStorage(PrefKey.notifyComplete) private var notifyComplete = false
    @AppStorage(PrefKey.notifyAttention) private var notifyAttention = false
    @AppStorage(PrefKey.notifyError) private var notifyError = false
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    private let retentionChoices: [(String, Double)] = [
        ("1 hour", 1), ("4 hours", 4), ("12 hours", 12), ("1 day", 24), ("3 days", 72), ("7 days", 168),
    ]

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setLogin($0) }))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("Approval required in System Settings › Login Items").font(.caption).foregroundStyle(.secondary)
                        Button("Open") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let e = loginError { Text(e).font(.caption).foregroundStyle(.red) }
            }
            Section("Menu bar") {
                Toggle("Show working-session count", isOn: $showCount)
                Toggle("Show elapsed turn duration", isOn: $showElapsed)
                Toggle("Show working directories in the session list", isOn: $showDirectories)
            }
            Section("Sessions") {
                Picker("Keep finished sessions for", selection: $retentionHours) {
                    ForEach(retentionChoices, id: \.1) { Text($0.0).tag($0.1) }
                }
                Text("Working and waiting sessions are never removed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("When a turn completes", isOn: $notifyComplete)
                Toggle("When Claude needs approval or input", isOn: $notifyAttention)
                Toggle("When a turn ends with an error", isOn: $notifyError)
                Text("Off by default. macOS asks for permission the first time one is enabled.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Claude Code integration") {
                LabeledContent("Hooks", value: hookStatusText)
                HStack {
                    Button(model.integrationNeedsSetup ? "Install Hooks…" : "Repair Hooks…") { IntegrationUI.confirmSetup(model) }
                    Button("Remove Hooks…") { IntegrationUI.confirmRemove(model) }
                        .disabled(!model.hooksInstalled)
                }
                Text("Adds or removes only Claude Status entries in ~/.claude/settings.json. A backup is written before every change.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("About") {
                LabeledContent("Version", value: ClaudeStatusVersion.current)
                LabeledContent("State folder", value: (model.paths.root.path as NSString).abbreviatingWithTildeInPath)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: notifyComplete) { _, on in if on { Notifier.requestAuthorizationIfNeeded() } }
        .onChange(of: notifyAttention) { _, on in if on { Notifier.requestAuthorizationIfNeeded() } }
        .onChange(of: notifyError) { _, on in if on { Notifier.requestAuthorizationIfNeeded() } }
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var hookStatusText: String {
        guard let h = model.health else { return "Checking…" }
        if !h.hookExecutablePresent && h.hookStatus.kind == .installed { return "Registered, helper missing" }
        switch h.hookStatus.kind {
        case .installed: return h.hookStatus.isHealthy ? "Installed" : "Needs repair"
        case .partial: return "Partially installed"
        case .notInstalled, .settingsMissing: return "Not installed"
        case .invalidSettings: return "Settings file unreadable"
        }
    }

    private func setLogin(_ on: Bool) {
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Could not change login item: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}

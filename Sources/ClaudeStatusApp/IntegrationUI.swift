import AppKit
import ClaudeStatusCore

/// Confirmation and result dialogs for changing the user's global Claude Code settings.
/// Nothing is written without an explicit click on the confirmation button.
@MainActor
enum IntegrationUI {
    static func confirmSetup(_ model: AppModel) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Set up Claude Code hooks?"
        alert.informativeText = """
        Claude Status will:
        • copy its hook helper to ~/Library/Application Support/ClaudeStatus/bin
        • add one Claude Status entry for each of 12 lifecycle events to ~/.claude/settings.json

        Existing settings and hooks are kept exactly as they are, and a backup of the file is saved first. \
        The hook never blocks or changes Claude's behaviour. You can remove it any time in Preferences.
        """
        alert.addButton(withTitle: "Install Hooks")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        show(model.setupIntegration(), title: "Claude Code hooks")
    }

    static func confirmRemove(_ model: AppModel) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Remove Claude Status hooks?"
        alert.informativeText = "Only Claude Status entries are removed from ~/.claude/settings.json. Other settings and hooks are kept, and a backup is saved first. Sessions stop updating until hooks are installed again."
        alert.addButton(withTitle: "Remove Hooks")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        show(model.removeIntegration(), title: "Claude Code hooks")
    }

    private static func show(_ result: (ok: Bool, message: String), title: String) {
        let a = NSAlert()
        a.alertStyle = result.ok ? .informational : .warning
        a.messageText = result.ok ? title : "\(title): not changed"
        a.informativeText = result.message
        a.runModal()
    }
}

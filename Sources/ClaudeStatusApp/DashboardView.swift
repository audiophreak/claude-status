import AppKit
import ClaudeStatusCore
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @AppStorage(PrefKey.showCount) private var showCount = true
    @AppStorage(PrefKey.showElapsed) private var showElapsed = false

    var body: some View {
        HStack(spacing: 3) {
            Image(nsImage: StatusStyle.menuBarImage(model.aggregate, activity: model.aggregateActivity))
            if let text = labelText { Text(text).monospacedDigit() }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var labelText: String? {
        var parts: [String] = []
        if showCount && model.counts.working > 0 { parts.append("\(model.counts.working)") }
        if showElapsed, let e = model.elapsedMenuText { parts.append(e) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var accessibilityText: String {
        let c = model.counts
        var bits: [String] = ["Claude Status: \(model.aggregate.label)"]
        if c.waiting > 0 { bits.append("\(c.waiting) waiting for you") }
        if c.error > 0 { bits.append("\(c.error) with errors") }
        if c.working - c.background > 0 { bits.append("\(c.working - c.background) working") }
        if c.background > 0 { bits.append("\(c.background) working in the background") }
        if c.unknown > 0 { bits.append("\(c.unknown) unknown") }
        return bits.joined(separator: ", ")
    }
}

struct DashboardView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PrefKey.showDirectories) private var showDirectories = false
    /// False only for offscreen snapshots (ImageRenderer cannot draw ScrollView content).
    var scrollable = true

    @State private var visible = false

    /// Elapsed times tick once per second only while the dashboard is open.
    private var rows: some View {
        TimelineView(.periodic(from: .now, by: visible ? 1 : 3600)) { ctx in
            VStack(alignment: .leading, spacing: 0) {
                let shown = visibleSessions
                ForEach(shown) { s in
                    SessionRow(session: s, now: ctx.date.timeIntervalSince1970, showDirectory: showDirectories)
                    if s.id != shown.last?.id { Divider().padding(.leading, 38) }
                }
            }
        }
    }

    private var visibleSessions: [EffectiveSession] { model.sessions.filter { !$0.dismissed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if visibleSessions.isEmpty {
                Text(model.hiddenCount > 0
                     ? "\(model.hiddenCount) finished session\(model.hiddenCount == 1 ? "" : "s") hidden. They reappear on their next event."
                     : "No Claude Code sessions detected.\nSessions appear when Claude Code starts or fires its next event.")
                    .font(.callout).foregroundStyle(.secondary)
                    .padding(.horizontal, 14).padding(.vertical, 12)
            } else {
                if scrollable {
                    ScrollView { rows }.frame(maxHeight: 380)
                } else {
                    rows
                }
            }
            Divider()
            healthSection
            Divider()
            footer
        }
        .frame(width: 380)
        .onAppear {
            visible = true
            model.reload()
            model.refreshHealth()
        }
        .onDisappear { visible = false }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Claude Status").font(.headline)
            Spacer()
            let c = model.counts
            Text(Presentation.summary(c)).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let h = model.health {
                HStack(spacing: 6) {
                    Image(systemName: h.level == .ok ? "checkmark.shield" : (h.level == .warning ? "exclamationmark.triangle" : "xmark.shield"))
                        .foregroundStyle(h.level == .ok ? Color.green : (h.level == .warning ? Color.orange : Color.red))
                        .accessibilityHidden(true)
                    Text(h.summary).font(.caption)
                    Spacer()
                    Text(h.lastEventAt.map { "Last event \(Format.ago(Date().timeIntervalSince1970 - $0))" } ?? "No events yet")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(h.problems.dropFirst(), id: \.self) { p in
                    Text("• \(p)").font(.caption2).foregroundStyle(.secondary)
                }
                Text("\(h.coverageText) · \(h.backgroundVisibilityText)")
                    .font(.caption2).foregroundStyle(.secondary)
                if model.integrationNeedsSetup {
                    Button("Set Up Claude Code Hooks…") { IntegrationUI.confirmSetup(model) }
                        .controlSize(.small)
                        .padding(.top, 2)
                }
                if h.unobservedClaudeProcesses > 0 {
                    Text("Unobserved sessions show as Unknown until their next prompt, tool call or turn end. No restart is needed.")
                        .font(.caption2).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Text("v\(ClaudeStatusVersion.current)").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Clear Finished") { model.clearFinished() }
                .help("Remove ended sessions and hide finished ones. Working (including background), waiting and unknown sessions are kept.")
            Button("Preferences…") {
                openWindow(id: "preferences")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .padding(.horizontal, 14).padding(.vertical, 8)
    }
}

struct SessionRow: View {
    let session: EffectiveSession
    let now: Double
    let showDirectory: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StateBadge(state: session.state, activity: session.activity, unobserved: session.unobserved).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                    if session.record.client != .unknown {
                        Text(session.record.client.label)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                    }
                    Spacer(minLength: 6)
                    Text(Presentation.timeText(session, now: now))
                        .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                }
                Text("\(session.label) — \(session.detail)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                if session.showsDimensions {
                    Text("Foreground: \(session.foregroundSummary) · Background: \(session.backgroundSummary.replacingOccurrences(of: " running", with: ""))")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                }
                if showDirectory, let cwd = session.record.cwd {
                    Text(abbreviate(cwd)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .help(session.unobserved ? "Claude process \(session.record.pid ?? 0) — not yet observed\n\(session.record.cwd ?? "")"
              : "Session \(session.record.sessionId)\n\(session.record.cwd ?? "")")
    }

    private var title: String {
        let r = session.record
        if let wt = r.worktreeName { return "\(r.displayName) · \(wt)" }
        return r.displayName
    }

    private func abbreviate(_ p: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }
}

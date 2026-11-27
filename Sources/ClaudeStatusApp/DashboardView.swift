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
        if showCount && model.counts.executing > 0 { parts.append("\(model.counts.executing)") }
        if showElapsed, let e = model.elapsedMenuText { parts.append(e) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private var accessibilityText: String {
        let c = model.counts
        var bits: [String] = ["Claude Status: \(model.aggregate.label)"]
        if c.waiting > 0 { bits.append("\(c.waiting) waiting for you") }
        if c.error > 0 { bits.append("\(c.error) with errors") }
        if c.working - c.background > 0 { bits.append("\(c.working - c.background) working") }
        if c.background - c.scheduled > 0 { bits.append("\(c.background - c.scheduled) working in the background") }
        if c.scheduled > 0 { bits.append("\(c.scheduled) with a continuation scheduled") }
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
        // `onDisappear` does not reliably fire when the menu bar panel closes; without this the
        // hidden dashboard kept redrawing every second (measured ~0.5 % CPU after first open).
        .background(WindowVisibilityReader { isVisible in
            guard isVisible != visible else { return }
            visible = isVisible
            if isVisible {
                model.reload()
                model.refreshHealth()
            }
        })
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
                Text(h.hooksText(now: Date().timeIntervalSince1970))
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
                // Background-only work is described by the foreground / background line below.
                Text(session.showsDimensions && session.activity == .background ? session.label : "\(session.label) — \(session.detail)")
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                if session.showsDimensions {
                    Text("Foreground: \(session.foregroundSummary) · Background: \(session.backgroundSummary)")
                        .font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(2)
                }
                if session.confidence != .confirmed && !session.unobserved {
                    Label(session.confidence == .partial ? "Partly observed" : "State uncertain", systemImage: "questionmark.circle.dashed")
                        .font(.system(size: 9)).foregroundStyle(.tertiary).labelStyle(.titleAndIcon)
                        .accessibilityLabel("Monitoring confidence: \(session.confidence.rawValue)")
                }
                if showDirectory, let cwd = session.record.cwd {
                    Text(abbreviate(cwd)).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .help(session.evidenceSummary(now: now) + (showDirectory ? "\n" + abbreviate(session.record.cwd ?? "") : ""))
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


/// Reports whether the hosting window is actually on screen (occlusion state), so periodic
/// redraws stop while the menu bar panel is closed.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ReaderView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? ReaderView)?.onChange = onChange
    }

    final class ReaderView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
            guard let w = window else { report(false); return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                              object: w, queue: .main) { [weak self] _ in
                self?.report(w.occlusionState.contains(.visible) && w.isVisible)
            }
            report(w.occlusionState.contains(.visible) && w.isVisible)
        }

        private func report(_ visible: Bool) {
            let cb = onChange
            DispatchQueue.main.async { cb?(visible) }
        }

        deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
    }
}

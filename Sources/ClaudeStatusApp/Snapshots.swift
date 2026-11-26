import AppKit
import ClaudeStatusCore
import SwiftUI

/// `ClaudeStatus --render-snapshots DIR` renders the app's real views (menu bar item, session
/// dashboard, preferences) inside offscreen windows with neutral demo sessions, in light and
/// dark appearance, and writes PNGs. It reads and writes no Claude Status state and needs no
/// Screen Recording permission (the app draws its own windows).
@MainActor
enum Snapshots {
    static func demoSessions(now: Double) -> [SessionRecord] {
        func r(_ id: String, _ name: String, _ state: SessionState, _ reason: StateReason? = nil, client: ClientType,
               started: Double? = nil, completed: Double? = nil, took: Double? = nil, wt: String? = nil,
               tools: Int = 0, subagents: Int = 0) -> SessionRecord {
            var x = SessionRecord(sessionId: "demo-\(id)", timestamp: now - 3600)
            x.state = state; x.reason = reason; x.client = client; x.gitRepoName = name; x.worktreeName = wt
            x.cwd = "/Users/demo/Code/\(name)"
            x.turnStartedAt = started; x.turnObservedFromStart = true
            x.lastCompletedAt = completed; x.lastTurnDuration = took; x.lastTurnDurationExact = true
            x.lastEventAt = completed ?? (now - 4)
            x.inFlightTools = (0..<tools).map { "t\($0)" }
            x.activeSubagents = subagents
            if state == .error { x.errorCategory = "rate_limit"; x.lastEventAt = now - 95 }
            return x
        }
        return [
            r("1", "acme-web", .working, client: .desktop, started: now - 754, tools: 1),
            r("2", "payments-api", .complete, client: .cli, completed: now - 480, took: 192),
            r("3", "docs-site", .waiting, .permission, client: .desktop, started: now - 65),
            r("4", "data-pipeline", .error, .apiError, client: .cli),
            r("5", "ios-app", .working, client: .cli, started: now - 31, wt: "login-flow", subagents: 2),
        ]
    }

    static func demoHealth(now: Double) -> MonitoringHealth {
        MonitoringHealth(
            hookStatus: HookInstallStatus(kind: .installed, installedEvents: HookEventName.registered.map(\.rawValue),
                                          missingEvents: [], duplicateEvents: [], mismatchedCommand: false, detail: nil),
            hookExecutablePresent: true, storeAccessible: true, lastEventAt: now - 4, corruptRecords: 0,
            unobservedClaudeProcesses: 0, problems: [])
    }

    static func render(to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date().timeIntervalSince1970
        for (name, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            let appearance = NSAppearance(named: name)!
            let model = AppModel()
            model.loadPreview(records: demoSessions(now: now), health: demoHealth(now: now), now: now)

            capture(DashboardView(model: model).background(.regularMaterial), appearance: appearance,
                    to: dir.appendingPathComponent("dashboard-\(suffix).png"))
            capture(PreferencesView(model: model), appearance: appearance,
                    to: dir.appendingPathComponent("preferences-\(suffix).png"))
            capture(menuBarStates(now: now), appearance: appearance,
                    to: dir.appendingPathComponent("menubar-\(suffix).png"))
        }
    }

    /// The real menu bar label for each aggregate state, on a menu-bar-like strip.
    static func menuBarStates(now: Double) -> some View {
        let cases: [(SessionState, String)] = [
            (.waiting, "Waiting — a session needs you (2 others working)"),
            (.error, "Error — a turn failed (1 other working)"),
            (.working, "Working — 2 sessions working"),
            (.unknown, "Unknown — state cannot be established"),
            (.complete, "Complete — ready for the next prompt"),
            (.idle, "Idle — no active sessions"),
        ]
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(cases.enumerated()), id: \.offset) { _, c in
                HStack(spacing: 12) {
                    MenuBarLabel(model: labelModel(c.0, now: now))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .frame(width: 64, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.06)))
                    Text(c.1).font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .frame(width: 420, alignment: .leading)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    static func labelModel(_ state: SessionState, now: Double) -> AppModel {
        var recs: [SessionRecord] = []
        func add(_ s: SessionState, _ i: Int) { var x = SessionRecord(sessionId: "l\(i)", timestamp: now); x.state = s; recs.append(x) }
        switch state {
        case .waiting: add(.waiting, 0); add(.working, 1); add(.working, 2)
        case .error: add(.error, 0); add(.working, 1)
        case .working: add(.working, 0); add(.working, 1)
        case .idle: break
        default: add(state, 0)
        }
        let m = AppModel()
        m.loadPreview(records: recs, health: nil, now: now)
        return m
    }

    /// Host a view in a borderless offscreen window and draw it (including AppKit controls).
    static func capture<V: View>(_ view: V, appearance: NSAppearance, to url: URL) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light))
        host.appearance = appearance
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = appearance
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        defer { window.orderOut(nil) }
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

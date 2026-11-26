import AppKit
import ClaudeStatusCore
import Combine
import Foundation

enum PrefKey {
    static let showCount = "showActiveCount"
    static let showElapsed = "showElapsedInMenuBar"
    static let retentionHours = "completedRetentionHours"
    static let notifyComplete = "notifyCompletion"
    static let notifyAttention = "notifyAttention"
    static let notifyError = "notifyError"
    static let showDirectories = "showWorkingDirectories"
}

/// Watches a directory for entry changes (create/rename/delete) using a vnode source.
final class DirectoryWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let handler: () -> Void

    init(url: URL, handler: @escaping () -> Void) {
        self.url = url
        self.handler = handler
    }

    func start() {
        stop()
        let fd = open(url.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self] in
            guard let self else { return }
            if src.data.contains(.delete) || src.data.contains(.rename) {
                self.start()   // directory replaced: re-arm
            }
            self.handler()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    func stop() {
        source?.cancel()
        source = nil
    }

    var isActive: Bool { source != nil }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var sessions: [EffectiveSession] = []
    @Published private(set) var aggregate: SessionState = .idle
    @Published private(set) var counts = Presentation.Counts()
    @Published private(set) var health: MonitoringHealth?
    @Published private(set) var watcherActive = false
    /// Bumped by the periodic timer only when the menu bar shows an elapsed duration.
    @Published private(set) var elapsedTick = 0

    let paths = StatusPaths.fromEnvironment()
    let settingsURL = ClaudePaths.userSettings()
    private lazy var store = SessionStore(paths: paths)
    private var watcher: DirectoryWatcher?
    private var timer: Timer?
    private var pendingReload = false
    private var lastWake: Double?
    private var livenessCache: [String: (alive: Bool?, at: Double)] = [:]
    private var corruptCount = 0
    private var records: [SessionRecord] = []
    private var tick = 0
    private var isPreview = false
    let notifier = Notifier()
    private var observers: [NSObjectProtocol] = []

    private var defaults: UserDefaults { .standard }

    init() {
        defaults.register(defaults: [
            PrefKey.showCount: true,
            PrefKey.showElapsed: false,
            PrefKey.retentionHours: 24.0,
            PrefKey.notifyComplete: false,
            PrefKey.notifyAttention: false,
            PrefKey.notifyError: false,
            PrefKey.showDirectories: false,
        ])
    }

    func start() {
        try? paths.ensureDirectories()
        refreshInstalledHelpersIfOutdated()
        watcher = DirectoryWatcher(url: paths.sessionsDir) { [weak self] in
            Task { @MainActor in self?.scheduleReload() }
        }
        watcher?.start()
        watcherActive = watcher?.isActive ?? false

        let t = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.periodic() }
        }
        t.tolerance = 10
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.lastWake = Date().timeIntervalSince1970
                self?.livenessCache.removeAll()
                self?.watcher?.start()
                self?.reload()
                self?.refreshHealth()
            }
        })
        reload()
        refreshHealth()
        applyRetention()
        reload()
    }

    // MARK: Refresh

    private func scheduleReload() {
        guard !pendingReload else { return }
        pendingReload = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            Task { @MainActor in
                self?.pendingReload = false
                self?.reload()
            }
        }
    }

    func reload() {
        guard !isPreview else { return }
        let (recs, corrupt) = store.loadAll()
        records = recs
        corruptCount = corrupt.count
        evaluate()
    }

    private func alive(_ r: SessionRecord, now: Double) -> Bool? {
        guard let pid = r.pid else { return nil }
        if let c = livenessCache[r.sessionId], now - c.at < 15 { return c.alive }
        let a = ProcessInspector.isAlive(pid: pid, startTime: r.pidStartTime)
        livenessCache[r.sessionId] = (a, now)
        return a
    }

    private func evaluate() {
        let now = Date().timeIntervalSince1970
        let evaluated = records.map { Presentation.evaluate($0, now: now, alive: alive($0, now: now), lastWake: lastWake) }
        let sorted = Presentation.sorted(evaluated)
        notifier.process(sorted, preferences: defaults)
        // Publish only real changes so idle refreshes do not re-render SwiftUI views.
        if sorted != sessions { sessions = sorted }
        let agg = Presentation.aggregate(sorted)
        if agg != aggregate { aggregate = agg }
        let c = Presentation.counts(sorted)
        if c != counts { counts = c }
        writeTestDump()
    }

    /// Integration-test aid: when `CLAUDE_STATUS_STATE_DUMP` names an absolute path inside a
    /// `CLAUDE_STATUS_HOME` override, write the evaluated state there after every refresh.
    /// Inert in normal use (neither variable is set).
    private func writeTestDump() {
        let env = ProcessInfo.processInfo.environment
        guard let home = env["CLAUDE_STATUS_HOME"], let dump = env["CLAUDE_STATUS_STATE_DUMP"],
              dump.hasPrefix(home + "/"), !dump.contains("/../") else { return }
        let obj: [String: Any] = [
            "writtenAt": Date().timeIntervalSince1970,
            "aggregate": aggregate.rawValue,
            "working": counts.working, "waiting": counts.waiting, "error": counts.error,
            "sessions": sessions.map { ["id": $0.id, "state": $0.state.rawValue, "ended": $0.ended, "detail": $0.detail] },
            "health": health?.level.rawValue ?? "unknown",
            "hookExecutablePresent": health?.hookExecutablePresent ?? false,
            "problems": health?.problems ?? [],
        ]
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
            try? SessionStore.atomicWrite(d, to: URL(fileURLWithPath: dump), mode: 0o600)
        }
    }

    private func periodic() {
        tick += 1
        livenessCache.removeAll()
        applyRetention()
        reload()
        if tick % 2 == 0 { refreshHealth() }
        if defaults.bool(forKey: PrefKey.showElapsed) && counts.working > 0 { elapsedTick &+= 1 }
        if !(watcher?.isActive ?? false) { watcher?.start(); watcherActive = watcher?.isActive ?? false }
    }

    func refreshHealth() {
        guard !isPreview else { return }
        let h = MonitoringHealth.check(paths: paths, settingsURL: settingsURL, records: records, corrupt: corruptCount)
        if h != health { health = h }
        writeTestDump()
    }

    // MARK: Claude Code integration (hooks)

    /// Hooks need (re)installation: missing, partial, pointing elsewhere, or helper missing.
    var integrationNeedsSetup: Bool {
        guard let h = health else { return false }
        if h.hookStatus.kind == .invalidSettings { return false }   // never edit an unparseable file
        return !h.hookStatus.isHealthy || !h.hookExecutablePresent
    }

    var hooksInstalled: Bool { health?.hookStatus.installedEvents.isEmpty == false }

    private var configurator: HookConfigurator {
        HookConfigurator(settingsURL: settingsURL, hookCommandPath: paths.hookExecutable.path, backupsDir: paths.backupsDir)
    }

    /// Install helpers from this app bundle and register hooks. Returns a user-facing message.
    func setupIntegration() -> (ok: Bool, message: String) {
        guard let helpers = HelperInstaller.bundledHelpersDirectory() else {
            return (false, "This copy of Claude Status has no bundled helpers. Reinstall the app.")
        }
        do {
            try HelperInstaller.install(from: helpers, paths: paths)
            var result: InstallResult?
            var lastError: Error?
            for _ in 0..<3 {
                do { result = try configurator.install(); break }
                catch ConfigError.concurrentModification { lastError = ConfigError.concurrentModification; usleep(300_000) }
            }
            guard let r = result else { throw lastError ?? ConfigError.concurrentModification }
            refreshHealth()
            if !r.changed { return (true, "Hooks were already installed. Helpers are up to date.") }
            return (true, "Hooks installed for \(r.addedEvents.count + r.updatedEvents.count) events." + (r.backupPath.map { "\nBackup of your previous settings: \($0)" } ?? ""))
        } catch {
            refreshHealth()
            return (false, "Nothing was changed in your Claude settings.\n\(error)")
        }
    }

    /// Remove only Claude Status hook handlers from ~/.claude/settings.json.
    func removeIntegration() -> (ok: Bool, message: String) {
        do {
            let r = try configurator.uninstall()
            refreshHealth()
            if !r.changed { return (true, "No Claude Status hooks were installed.") }
            return (true, "Removed \(r.removedHooks) Claude Status hook handlers. Other settings and hooks were kept." + (r.backupPath.map { "\nBackup: \($0)" } ?? ""))
        } catch {
            refreshHealth()
            return (false, "Nothing was changed.\n\(error)")
        }
    }

    /// After an app update, refresh already-installed helpers so hooks run the new version.
    private func refreshInstalledHelpersIfOutdated() {
        guard !isPreview, let helpers = HelperInstaller.bundledHelpersDirectory(),
              FileManager.default.fileExists(atPath: paths.hookExecutable.path),
              !HelperInstaller.isUpToDate(from: helpers, paths: paths) else { return }
        _ = try? HelperInstaller.install(from: helpers, paths: paths)
    }

    // MARK: Cleanup

    var retentionSeconds: Double { max(defaults.double(forKey: PrefKey.retentionHours), 0.25) * 3600 }

    private func applyRetention() {
        remove(retention: retentionSeconds)
    }

    func clearFinished() {
        remove(retention: nil)
        reload()
    }

    /// Delete removable records. Each candidate is re-read and re-evaluated under the store
    /// lock, so a session a hook just made active again is never removed.
    private func remove(retention: Double?) {
        let now = Date().timeIntervalSince1970
        let candidates = sessions.filter { Presentation.isRemovable($0, now: now, retention: retention) }.map(\.id)
        guard !candidates.isEmpty else { return }
        let store = self.store
        try? store.withLock(timeout: 0.5) {
            for id in candidates {
                guard case .record(let r) = store.load(id) else { continue }
                let fresh = Presentation.evaluate(r, now: now, alive: alive(r, now: now), lastWake: lastWake)
                if Presentation.isRemovable(fresh, now: now, retention: retention) { try? store.delete(id) }
            }
        }
    }

    /// Snapshot rendering only: display the given records without touching the store.
    func loadPreview(records: [SessionRecord], health: MonitoringHealth?, now: Double) {
        isPreview = true
        let evaluated = Presentation.sorted(records.map { Presentation.evaluate($0, now: now, alive: nil, lastWake: nil) })
        sessions = evaluated
        aggregate = Presentation.aggregate(evaluated)
        counts = Presentation.counts(evaluated)
        self.health = health
    }

    var elapsedMenuText: String? {
        guard defaults.bool(forKey: PrefKey.showElapsed) else { return nil }
        let now = Date().timeIntervalSince1970
        let starts = sessions.filter { $0.state == .working }.compactMap(\.record.turnStartedAt)
        guard let oldest = starts.min() else { return nil }
        return Format.duration(now - oldest)
    }
}

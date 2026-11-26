import ClaudeStatusCore
import Foundation
import UserNotifications

/// Optional user notifications. Off by default; authorization is requested only when the
/// user enables a notification preference. Each (session, turn, state) notifies at most once.
@MainActor
final class Notifier {
    private var lastStates: [String: SessionState] = [:]
    private var notified: [String] = []
    private var primed = false

    static func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func process(_ sessions: [EffectiveSession], preferences d: UserDefaults) {
        defer {
            lastStates = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.state) })
            primed = true
        }
        // The first evaluation after launch only records state: no notifications for history.
        guard primed else { return }
        for s in sessions where !s.ended {
            guard let prev = lastStates[s.id], prev != s.state else { continue }
            let enabled: Bool
            let title: String
            switch s.state {
            case .complete: enabled = d.bool(forKey: PrefKey.notifyComplete); title = "Claude finished"
            case .waiting: enabled = d.bool(forKey: PrefKey.notifyAttention); title = "Claude needs your attention"
            case .error: enabled = d.bool(forKey: PrefKey.notifyError); title = "Claude stopped with an error"
            default: continue
            }
            guard enabled else { continue }
            let key = "\(s.id)-\(s.record.turnSeq)-\(s.state.rawValue)-\(s.record.reason?.rawValue ?? "")"
            guard !notified.contains(key) else { continue }
            notified.append(key)
            if notified.count > 500 { notified.removeFirst(notified.count - 500) }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = "\(s.record.displayName) — \(s.detail)"
            let req = UNNotificationRequest(identifier: key, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { _ in }
        }
    }
}

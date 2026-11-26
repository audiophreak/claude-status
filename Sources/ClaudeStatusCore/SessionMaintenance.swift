import Foundation

/// Retention cleanup and "Clear Finished", shared by the app and `claude-status-ctl`.
public enum SessionMaintenance {
    public struct Result: Equatable, Sendable {
        public var deleted = 0
        public var dismissed = 0
        public init() {}
    }

    /// Re-read and re-evaluate every record under the store lock, so a session a hook just
    /// made active again is never touched.
    /// - Parameters:
    ///   - retention: nil = explicit "Clear Finished"; otherwise minimum age in seconds.
    ///   - alive: process liveness for a record (nil = unknown).
    public static func cleanup(store: SessionStore, now: Double, retention: Double?, lastWake: Double? = nil,
                               alive: (SessionRecord) -> Bool?) -> Result {
        var result = Result()
        try? store.withLock(timeout: 0.5) {
            let (records, corrupt) = store.loadAll()
            for r in records {
                let a = alive(r)
                let e = Presentation.evaluate(r, now: now, alive: a, lastWake: lastWake)
                switch Presentation.cleanupAction(e, alive: a, now: now, retention: retention) {
                case .keep:
                    break
                case .dismiss:
                    var d = r
                    d.dismissed = true
                    if (try? store.save(d)) != nil { result.dismissed += 1 }
                case .delete:
                    if (try? store.delete(r.sessionId)) != nil { result.deleted += 1 }
                }
            }
            if retention == nil { for c in corrupt { store.deleteCorrupt(c) } }
        }
        return result
    }

    public static func liveness(_ r: SessionRecord) -> Bool? {
        r.pid.map { ProcessInspector.isAlive(pid: $0, startTime: r.pidStartTime) }
    }
}

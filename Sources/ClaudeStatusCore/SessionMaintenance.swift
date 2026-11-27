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
    /// Upper bound on stored records. Beyond it, the oldest records that are not needed to
    /// track ongoing or possibly ongoing work (ended, process exited) are deleted first.
    public static let maxRecords = 200

    public static func cleanup(store: SessionStore, now: Double, retention: Double?, lastWake: Double? = nil,
                               maxRecords: Int = SessionMaintenance.maxRecords,
                               alive: (SessionRecord) -> Bool?) -> Result {
        var result = Result()
        try? store.withLock(timeout: 0.5) {
            let (records, corrupt) = store.loadAll()
            var deleted = Set<String>()
            defer {
                // Bound storage growth: drop the oldest finished records whose process is gone.
                let remaining = records.filter { !deleted.contains($0.sessionId) }
                if remaining.count > maxRecords {
                    let candidates = remaining
                        .filter { r in
                            let a = alive(r)
                            let e = Presentation.evaluate(r, now: now, alive: a, lastWake: lastWake)
                            return e.ended || (a == false && !e.state.isActive)
                        }
                        .sorted { $0.lastEventAt < $1.lastEventAt }
                    for r in candidates.prefix(remaining.count - maxRecords) {
                        if (try? store.delete(r.sessionId)) != nil { result.deleted += 1 }
                    }
                }
            }
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
                    if (try? store.delete(r.sessionId)) != nil { result.deleted += 1; deleted.insert(r.sessionId) }
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

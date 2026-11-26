import Darwin
import Foundation

/// Bounded, line-oriented diagnostic log. Contains event names, session-id prefixes, timings
/// and error codes only. Rotates to `hook.log.1` at `maxBytes`.
public struct DiagnosticsLog: Sendable {
    public let url: URL
    public var maxBytes: Int = 256 * 1024

    public init(url: URL) { self.url = url }

    public func append(_ line: String) {
        let path = url.path
        var st = stat()
        if stat(path, &st) == 0, Int(st.st_size) > maxBytes {
            _ = rename(path, path + ".1")
        }
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        let clean = String(line.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.prefix(512).map(Character.init))
        let data = Array((clean + "\n").utf8)
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }
}

/// Everything the hook does, in testable form. Never throws, never writes to stdout.
public enum HookRunner {
    public struct Outcome: Equatable {
        public var accepted: Bool
        public var detail: String
        public var record: SessionRecord?
        /// Privacy-safe evidence for the log: background task counts and statuses only.
        public var evidence: String = ""
    }

    /// `bg=2(shell:running,subagent:running) wake=1` for Stop / SubagentStop; `bg=?` when the
    /// documented `background_tasks` array was absent. Only type labels and statuses.
    public static func evidence(_ e: HookEvent) -> String {
        guard e.name == .stop || e.name == .subagentStop else { return "" }
        var out: String
        if let tasks = e.backgroundTasks {
            out = "bg=\(tasks.count)"
            if !tasks.isEmpty {
                let items = tasks.prefix(8).map { "\($0.type.replacingOccurrences(of: " ", with: "_")):\($0.status)" }
                out += "(\(items.joined(separator: ",")))"
            }
        } else {
            out = "bg=?"
        }
        if let sc = e.schedules { out += " wake=\(sc.oneShot) cron=\(sc.recurring)" }
        if e.agentId != nil { out += " agent" }
        return out
    }

    /// Read stdin retaining at most `limit` bytes; drains the rest so the writer never blocks.
    public static func readBounded(fd: Int32, limit: Int) -> (Data, truncated: Bool) {
        var out = Data()
        var truncated = false
        var buf = [UInt8](repeating: 0, count: 65536)
        var total = 0
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { if errno == EINTR { continue }; break }
            if n == 0 { break }
            total += n
            if out.count < limit {
                let take = min(n, limit - out.count)
                out.append(buf, count: take)
                if take < n { truncated = true }
            } else {
                truncated = true
            }
            if total > 512 * 1024 * 1024 { truncated = true; break }   // absolute safety bound
        }
        return (out, truncated)
    }

    public static func clientType(env: [String: String]) -> (ClientType, String?) {
        let ep = env["CLAUDE_CODE_ENTRYPOINT"].flatMap { Validate.token($0, maxLength: 40) ? $0 : nil }
        if ep == "claude-desktop" || env["CLAUDE_CODE_DESKTOP_APP_VERSION"] != nil { return (.desktop, ep) }
        // `cli` = interactive CLI; `sdk-cli` = the same CLI binary in print mode (`claude -p`).
        if ep == "cli" || ep == "sdk-cli" { return (.cli, ep) }
        return (.unknown, ep)
    }

    public static func context(env: [String: String], ppid: Int32 = getppid()) -> HookContext {
        let (client, ep) = clientType(env: env)
        var ctx = HookContext(client: client, entrypoint: ep)
        if let pd = env["CLAUDE_PROJECT_DIR"], Validate.absolutePath(pd) { ctx.projectDir = pd }
        if let p = ProcessInspector.findClaudeAncestor(env: env, startingAt: ppid) {
            ctx.pid = p.pid
            ctx.pidStartTime = p.startTime
        }
        return ctx
    }

    public static func process(payload: Data, truncated: Bool, timestamp: Double,
                               context: HookContext, paths: StatusPaths) -> Outcome {
        let event: HookEvent
        do {
            event = try HookEventParser.parse(payload, timestamp: timestamp, truncated: truncated)
        } catch {
            return Outcome(accepted: false, detail: "rejected:\(error)", record: nil)
        }
        let store = SessionStore(paths: paths)
        do {
            var note = "ok"
            let rec: SessionRecord = try store.withLock {
                var previous: SessionRecord? = nil
                switch store.load(event.sessionId) {
                case .record(let r): previous = r
                case .corrupt: note = "ok-corrupt-replaced"
                case .missing: break
                }
                let next = StateMachine.reduce(previous, event, context: context) { cwd in
                    ProjectInfo.detect(from: cwd)
                }
                if next != previous { try store.save(next) }
                if let p = previous, next.ignoredOutOfOrder > p.ignoredOutOfOrder { note = "ignored-out-of-order" }
                return next
            }
            return Outcome(accepted: true, detail: note, record: rec, evidence: evidence(event))
        } catch {
            return Outcome(accepted: false, detail: "store:\(error)", record: nil)
        }
    }

    /// Entry point used by the `claude-status-hook` executable.
    public static func main(env: [String: String] = ProcessInfo.processInfo.environment) {
        signal(SIGPIPE, SIG_IGN)
        let started = Date().timeIntervalSince1970
        let paths = StatusPaths.fromEnvironment(env)
        if env["CLAUDE_STATUS_DISABLE"] == "1" { return }
        let (data, truncated) = readBounded(fd: STDIN_FILENO, limit: HookEventParser.maxParsedBytes)
        let ctx = context(env: env)
        let outcome = process(payload: data, truncated: truncated, timestamp: started, context: ctx, paths: paths)
        let micros = Int((Date().timeIntervalSince1970 - started) * 1_000_000)
        let sid = outcome.record.map { String($0.sessionId.prefix(8)) } ?? "-"
        let ev = outcome.record?.lastEventName ?? "-"
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: started))
        try? paths.ensureDirectories()
        DiagnosticsLog(url: paths.hookLog).append("\(iso) \(ev) \(sid) \(outcome.detail) \(micros)us bytes=\(data.count)\(truncated ? " truncated" : "")\(outcome.evidence.isEmpty ? "" : " " + outcome.evidence)")
    }
}

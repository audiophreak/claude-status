import Darwin
import Foundation

/// Minimal, permission-free process inspection via libproc (same-user processes only).
public enum ProcessInspector {
    public struct Info: Equatable, Sendable {
        public var pid: Int32
        public var ppid: Int32
        public var uid: UInt32
        public var name: String
        public var startTime: Double
    }

    public static func info(_ pid: Int32) -> Info? {
        guard pid > 1 else { return nil }
        var bsd = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        let n = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, size)
        guard n == size else { return nil }
        var nameTuple = bsd.pbi_name
        var commTuple = bsd.pbi_comm
        let nameCap = MemoryLayout.size(ofValue: nameTuple)
        let commCap = MemoryLayout.size(ofValue: commTuple)
        let name = withUnsafePointer(to: &nameTuple) { p -> String in
            p.withMemoryRebound(to: CChar.self, capacity: nameCap) { String(cString: $0) }
        }
        let comm = withUnsafePointer(to: &commTuple) { p -> String in
            p.withMemoryRebound(to: CChar.self, capacity: commCap) { String(cString: $0) }
        }
        let start = Double(bsd.pbi_start_tvsec) + Double(bsd.pbi_start_tvusec) / 1_000_000
        return Info(pid: pid, ppid: Int32(bsd.pbi_ppid), uid: bsd.pbi_uid,
                    name: name.isEmpty ? comm : name, startTime: start)
    }

    public static func executablePath(_ pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        guard n > 0 else { return nil }
        return String(cString: buf)
    }

    /// A process is a Claude Code process when its executable is named exactly `claude`.
    public static func isClaudeProcess(_ info: Info) -> Bool {
        if info.name == "claude" { return true }
        if let p = executablePath(info.pid), (p as NSString).lastPathComponent == "claude" { return true }
        return false
    }

    /// Locate the Claude Code process that launched this hook. Prefers the `CLAUDE_PID`
    /// environment variable (validated), otherwise walks up to 6 ancestors.
    public static func findClaudeAncestor(env: [String: String], startingAt ppid: Int32 = getppid()) -> Info? {
        let me = getuid()
        if let s = env["CLAUDE_PID"], let pid = Int32(s), let i = info(pid), i.uid == me, isClaudeProcess(i) {
            return i
        }
        var pid = ppid
        for _ in 0..<6 {
            guard let i = info(pid), i.uid == me else { return nil }
            if isClaudeProcess(i) { return i }
            if i.ppid <= 1 { return nil }
            pid = i.ppid
        }
        return nil
    }

    /// Liveness with PID-reuse protection: the process must exist with the recorded start time.
    public static func isAlive(pid: Int32, startTime: Double?) -> Bool {
        guard let i = info(pid) else { return false }
        if let st = startTime { return abs(i.startTime - st) < 1.0 }
        return true
    }

    /// All same-user processes whose executable is named `claude`.
    public static func claudeProcesses() -> [Info] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) + 64)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard n > 0 else { return [] }
        let me = getuid()
        var out: [Info] = []
        for pid in pids.prefix(Int(n)) where pid > 1 {
            guard let i = info(pid), i.uid == me, i.name == "claude" else { continue }
            out.append(i)
        }
        return out
    }
}

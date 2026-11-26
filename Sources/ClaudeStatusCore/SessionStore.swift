import Darwin
import Foundation

public enum StoreError: Error, Equatable {
    case lockTimeout
    case io(String)
}

/// Per-session JSON files under `sessions/`, written atomically (temp file + rename) with
/// mode 0600 and serialised by an advisory `flock` on a single store lock file.
public struct SessionStore: Sendable {
    public let paths: StatusPaths
    public static let maxRecordBytes = 256 * 1024

    public init(paths: StatusPaths) { self.paths = paths }

    // MARK: Locking

    /// Run `body` holding an exclusive lock. Gives up after `timeout` seconds (fail open).
    public func withLock<T>(timeout: Double = 1.0, _ body: () throws -> T) throws -> T {
        try paths.ensureDirectories()
        let fd = open(paths.lockFile.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw StoreError.io("open lock: errno \(errno)") }
        defer { close(fd) }
        let deadline = Date().timeIntervalSince1970 + timeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw StoreError.io("flock: errno \(errno)") }
            if Date().timeIntervalSince1970 > deadline { throw StoreError.lockTimeout }
            usleep(2_000)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    // MARK: Reading

    public enum LoadResult: Equatable {
        case missing
        case corrupt
        case record(SessionRecord)
    }

    public func load(_ sessionId: String) -> LoadResult {
        guard Validate.sessionId(sessionId) else { return .corrupt }
        return loadFile(paths.sessionFile(sessionId), expectedId: sessionId)
    }

    func loadFile(_ url: URL, expectedId: String?) -> LoadResult {
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        if fd < 0 { return errno == ENOENT ? .missing : .corrupt }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? handle.read(upToCount: Self.maxRecordBytes + 1),
              data.count <= Self.maxRecordBytes else { return .corrupt }
        guard let rec = try? JSONDecoder().decode(SessionRecord.self, from: data),
              rec.schemaVersion == SessionRecord.schema,
              Validate.sessionId(rec.sessionId),
              expectedId == nil || rec.sessionId == expectedId else { return .corrupt }
        return .record(rec)
    }

    /// All valid records. Corrupt files are reported separately (never crash, never trusted).
    public func loadAll() -> (records: [SessionRecord], corrupt: [String]) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: paths.sessionsDir.path) else {
            return ([], [])
        }
        var records: [SessionRecord] = []
        var corrupt: [String] = []
        for name in names where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let sid = String(name.dropLast(5))
            guard Validate.sessionId(sid) else { corrupt.append(name); continue }
            switch loadFile(paths.sessionsDir.appendingPathComponent(name), expectedId: sid) {
            case .record(let r): records.append(r)
            case .corrupt: corrupt.append(name)
            case .missing: break
            }
        }
        return (records, corrupt)
    }

    // MARK: Writing

    public func save(_ record: SessionRecord) throws {
        guard Validate.sessionId(record.sessionId) else { throw StoreError.io("invalid session id") }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(record)
        try Self.atomicWrite(data, to: paths.sessionFile(record.sessionId), mode: 0o600)
    }

    /// Delete a record (and nothing else). Caller should hold the lock.
    public func delete(_ sessionId: String) throws {
        guard Validate.sessionId(sessionId) else { return }
        let path = paths.sessionFile(sessionId).path
        if unlink(path) != 0 && errno != ENOENT { throw StoreError.io("unlink: errno \(errno)") }
    }

    /// Remove corrupt record files by exact name (only `*.json` directly under sessions/).
    public func deleteCorrupt(_ name: String) {
        guard name.hasSuffix(".json"), !name.contains("/"), !name.hasPrefix(".") else { return }
        _ = unlink(paths.sessionsDir.appendingPathComponent(name).path)
    }

    /// Write via a unique temp file in the same directory, fsync, then rename(2).
    public static func atomicWrite(_ data: Data, to url: URL, mode: mode_t) throws {
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).tmp.\(getpid()).\(UInt32.random(in: 0...UInt32.max))")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw StoreError.io("create temp: errno \(errno)") }
        var ok = false
        defer {
            if !ok { _ = unlink(tmp.path) }
        }
        let written = data.withUnsafeBytes { buf -> Int in
            guard let base = buf.baseAddress else { return 0 }
            var off = 0
            while off < buf.count {
                let n = write(fd, base + off, buf.count - off)
                if n <= 0 { if errno == EINTR { continue }; return -1 }
                off += n
            }
            return off
        }
        _ = fchmod(fd, mode)
        _ = fsync(fd)
        close(fd)
        guard written == data.count else { throw StoreError.io("short write") }
        guard rename(tmp.path, url.path) == 0 else { throw StoreError.io("rename: errno \(errno)") }
        ok = true
    }
}

import CryptoKit
import Darwin
import Foundation

public enum ConfigError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case invalidJSON(String)
    case invalidStructure(String)
    case concurrentModification
    case verificationFailed(String)
    case writeFailed(String)
    case refused(String)

    public var description: String {
        switch self {
        case .unreadable(let s): return "settings file unreadable: \(s)"
        case .invalidJSON(let s): return "settings file is not valid JSON: \(s)"
        case .invalidStructure(let s): return "unexpected settings structure: \(s)"
        case .concurrentModification: return "settings file changed while it was being updated; nothing was written"
        case .verificationFailed(let s): return "verification failed: \(s)"
        case .writeFailed(let s): return "write failed: \(s)"
        case .refused(let s): return "refused: \(s)"
        }
    }
}

/// Health of the Claude Status hook registration in a settings file.
public struct HookInstallStatus: Equatable, Sendable {
    public enum Kind: String, Sendable { case installed, partial, notInstalled, settingsMissing, invalidSettings }
    public var kind: Kind
    public var installedEvents: [String]
    public var missingEvents: [String]
    public var duplicateEvents: [String]
    public var mismatchedCommand: Bool
    public var detail: String?

    public var isHealthy: Bool { kind == .installed && duplicateEvents.isEmpty && !mismatchedCommand }

    public init(kind: Kind, installedEvents: [String], missingEvents: [String], duplicateEvents: [String],
                mismatchedCommand: Bool, detail: String?) {
        self.kind = kind; self.installedEvents = installedEvents; self.missingEvents = missingEvents
        self.duplicateEvents = duplicateEvents; self.mismatchedCommand = mismatchedCommand; self.detail = detail
    }
}

public struct InstallResult: Equatable, Sendable {
    public var changed: Bool
    public var addedEvents: [String]
    public var updatedEvents: [String]
    public var removedDuplicates: Int
    public var backupPath: String?
}

public struct UninstallResult: Equatable, Sendable {
    public var changed: Bool
    public var removedHooks: Int
    public var removedEvents: [String]
    public var backupPath: String?
}

/// Structured, order-preserving editing of a Claude Code settings file.
///
/// Safety properties (all verified before the file is replaced):
/// 1. Only hook handlers whose command contains `claude-status-hook` are added/removed.
/// 2. `strip(new) == strip(original)`: removing Claude Status handlers from both versions
///    yields identical JSON, so every other setting and hook is semantically unchanged.
/// 3. The file is re-read immediately before the atomic rename; if its bytes differ from
///    what was read at the start, the update is abandoned (`concurrentModification`).
/// 4. A timestamped backup of the original bytes is written (mode 0600) before replacing.
public struct HookConfigurator {
    public let settingsURL: URL
    public let hookCommandPath: String
    public let backupsDir: URL
    public var events: [String] = HookEventName.registered.map(\.rawValue)
    public var timeoutSeconds = 5
    /// Test seam: called after the new content is prepared and before the final re-read.
    public var beforeCommit: (() -> Void)? = nil

    public init(settingsURL: URL, hookCommandPath: String, backupsDir: URL) {
        self.settingsURL = settingsURL
        self.hookCommandPath = hookCommandPath
        self.backupsDir = backupsDir
    }

    /// The exact command string registered. Quoted because the path contains spaces.
    public var hookCommand: String { "\"\(hookCommandPath)\"" }

    public static func isOurs(_ handler: JSONValue) -> Bool {
        guard let cmd = handler["command"]?.stringValue else { return false }
        return cmd.contains(ClaudeStatusVersion.hookMarker)
    }

    var ourHandler: JSONValue {
        .object([("type", .string("command")), ("command", .string(hookCommand)), ("timeout", .number(String(timeoutSeconds)))])
    }

    // MARK: - File IO

    /// The real file to edit (follows a symlinked settings.json to its target).
    var resolvedURL: URL { settingsURL.resolvingSymlinksInPath() }

    func readBytes() throws -> Data? {
        let url = resolvedURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let h = try? FileHandle(forReadingFrom: url) else { throw ConfigError.unreadable(url.path) }
        defer { try? h.close() }
        let data = (try? h.read(upToCount: OrderedJSONParser.maxBytes + 1)) ?? Data()
        guard data.count <= OrderedJSONParser.maxBytes else { throw ConfigError.unreadable("file too large") }
        return data
    }

    static func parseRoot(_ data: Data?) throws -> JSONValue {
        guard let data = data, !data.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) else {
            return .object([])
        }
        let v: JSONValue
        do { v = try OrderedJSONParser.parse(data) } catch { throw ConfigError.invalidJSON("\(error)") }
        guard case .object = v else { throw ConfigError.invalidStructure("top level is not an object") }
        try validateHooksShape(v)
        return v
    }

    static func validateHooksShape(_ root: JSONValue) throws {
        guard let hooks = root["hooks"] else { return }
        guard case .object(let events) = hooks else { throw ConfigError.invalidStructure("\"hooks\" is not an object") }
        for (name, groups) in events {
            guard case .array(let gs) = groups else { throw ConfigError.invalidStructure("hooks.\(name) is not an array") }
            for g in gs {
                guard case .object = g else { throw ConfigError.invalidStructure("hooks.\(name) has a non-object entry") }
                if let hs = g["hooks"], hs.arrayValue == nil {
                    throw ConfigError.invalidStructure("hooks.\(name)[].hooks is not an array")
                }
            }
        }
    }

    // MARK: - Pure transforms

    /// Remove every Claude Status handler; drop groups that become empty because of it.
    public static func strip(_ root: JSONValue) -> (JSONValue, removed: Int, events: [String]) {
        guard case .object(var top) = root, let hIdx = top.lastIndex(where: { $0.0 == "hooks" }),
              case .object(var events) = top[hIdx].1 else { return (root, 0, []) }
        var removed = 0
        var touched: [String] = []
        for ei in events.indices {
            guard case .array(let groups) = events[ei].1 else { continue }
            var newGroups: [JSONValue] = []
            var changed = false
            for g in groups {
                guard case .object(var gm) = g, let hi = gm.lastIndex(where: { $0.0 == "hooks" }),
                      case .array(let handlers) = gm[hi].1 else { newGroups.append(g); continue }
                let kept = handlers.filter { !isOurs($0) }
                if kept.count == handlers.count { newGroups.append(g); continue }
                removed += handlers.count - kept.count
                changed = true
                if kept.isEmpty { continue }
                gm[hi].1 = .array(kept)
                newGroups.append(.object(gm))
            }
            if changed {
                touched.append(events[ei].0)
                events[ei].1 = .array(newGroups)
            }
        }
        // Drop event keys that only existed for Claude Status.
        events.removeAll { pair in touched.contains(pair.0) && (pair.1.arrayValue?.isEmpty ?? false) }
        if events.isEmpty, removed > 0 {
            top.remove(at: hIdx)
        } else {
            top[hIdx].1 = .object(events)
        }
        return (.object(top), removed, touched)
    }

    /// Comparison form for preservation checks: Claude Status handlers removed, and an empty
    /// `"hooks": {}` treated as equivalent to an absent `hooks` key.
    public static func normalized(_ root: JSONValue) -> JSONValue {
        let stripped = strip(root).0
        guard case .object(var top) = stripped else { return stripped }
        top.removeAll { $0.0 == "hooks" && $0.1 == .object([]) }
        return .object(top)
    }

    /// Idempotent install transform. A healthy registration is left byte-for-byte alone;
    /// otherwise every existing Claude Status handler is removed and exactly one handler
    /// group (no matcher = all) is appended per registered event.
    func applyInstall(_ root: JSONValue) -> (JSONValue, added: [String], updated: [String], dupes: Int) {
        let current = status(of: root)
        if current.isHealthy { return (root, [], [], 0) }
        let dupes = current.duplicateEvents.count
        let (stripped, _, _) = Self.strip(root)
        guard case .object(var top) = stripped else { return (root, [], [], 0) }
        var events: [(String, JSONValue)] = []
        let hIdx = top.lastIndex(where: { $0.0 == "hooks" })
        if let hIdx, case .object(let e) = top[hIdx].1 { events = e }
        let group: JSONValue = .object([("hooks", .array([ourHandler]))])
        for event in self.events {
            if let idx = events.firstIndex(where: { $0.0 == event }), case .array(var g) = events[idx].1 {
                g.append(group)
                events[idx].1 = .array(g)
            } else {
                events.append((event, .array([group])))
            }
        }
        if let hIdx { top[hIdx].1 = .object(events) } else { top.append(("hooks", .object(events))) }
        return (.object(top), current.missingEvents, current.installedEvents, dupes)
    }

    // MARK: - Status

    public func status() -> HookInstallStatus {
        let data: Data?
        do { data = try readBytes() } catch {
            return HookInstallStatus(kind: .invalidSettings, installedEvents: [], missingEvents: events,
                                     duplicateEvents: [], mismatchedCommand: false, detail: "\(error)")
        }
        guard data != nil else {
            return HookInstallStatus(kind: .settingsMissing, installedEvents: [], missingEvents: events,
                                     duplicateEvents: [], mismatchedCommand: false, detail: nil)
        }
        let root: JSONValue
        do { root = try Self.parseRoot(data) } catch {
            return HookInstallStatus(kind: .invalidSettings, installedEvents: [], missingEvents: events,
                                     duplicateEvents: [], mismatchedCommand: false, detail: "\(error)")
        }
        return status(of: root)
    }

    public func status(of root: JSONValue) -> HookInstallStatus {
        var installed: [String] = [], missing: [String] = [], dup: [String] = []
        var mismatch = false
        for event in events {
            var count = 0
            for g in root["hooks"]?[event]?.arrayValue ?? [] {
                for h in g["hooks"]?.arrayValue ?? [] where Self.isOurs(h) {
                    count += 1
                    if h["command"]?.stringValue != hookCommand { mismatch = true }
                    if let m = g["matcher"]?.stringValue, m != "", m != "*" { mismatch = true }
                }
            }
            if count == 0 { missing.append(event) } else { installed.append(event) }
            if count > 1 { dup.append(event) }
        }
        let kind: HookInstallStatus.Kind = missing.isEmpty ? .installed : (installed.isEmpty ? .notInstalled : .partial)
        return HookInstallStatus(kind: kind, installedEvents: installed, missingEvents: missing,
                                 duplicateEvents: dup, mismatchedCommand: mismatch, detail: nil)
    }

    // MARK: - Mutations

    public func install(dryRun: Bool = false, now: Date = Date()) throws -> InstallResult {
        let originalData = try readBytes()
        let original = try Self.parseRoot(originalData)
        let (updated, added, changedEvents, dupes) = applyInstall(original)
        if updated == original {
            return InstallResult(changed: false, addedEvents: [], updatedEvents: [], removedDuplicates: 0, backupPath: nil)
        }
        // Verification 1: everything except our handlers is unchanged.
        guard Self.normalized(updated) == Self.normalized(original) else {
            throw ConfigError.verificationFailed("non-Claude-Status content would change")
        }
        // Verification 2: the result reports fully installed.
        guard status(of: updated).isHealthy else { throw ConfigError.verificationFailed("result is not fully installed") }
        if dryRun {
            return InstallResult(changed: true, addedEvents: added, updatedEvents: changedEvents, removedDuplicates: dupes, backupPath: nil)
        }
        let backup = try commit(original: originalData, new: updated, now: now, tag: "install")
        return InstallResult(changed: true, addedEvents: added, updatedEvents: changedEvents, removedDuplicates: dupes, backupPath: backup)
    }

    public func uninstall(dryRun: Bool = false, now: Date = Date()) throws -> UninstallResult {
        let originalData = try readBytes()
        guard originalData != nil else { return UninstallResult(changed: false, removedHooks: 0, removedEvents: [], backupPath: nil) }
        let original = try Self.parseRoot(originalData)
        let (stripped, removed, touched) = Self.strip(original)
        guard removed > 0 else { return UninstallResult(changed: false, removedHooks: 0, removedEvents: [], backupPath: nil) }
        guard Self.strip(stripped).0 == stripped, status(of: stripped).installedEvents.isEmpty else {
            throw ConfigError.verificationFailed("handlers remain after uninstall")
        }
        if dryRun { return UninstallResult(changed: true, removedHooks: removed, removedEvents: touched, backupPath: nil) }
        let backup = try commit(original: originalData, new: stripped, now: now, tag: "uninstall")
        return UninstallResult(changed: true, removedHooks: removed, removedEvents: touched, backupPath: backup)
    }

    /// Serialise, back up, re-check for concurrent modification, atomically replace, verify.
    func commit(original: Data?, new: JSONValue, now: Date, tag: String) throws -> String? {
        var text = OrderedJSONWriter.write(new)
        if let o = original, o.last == 0x0A || o.isEmpty { text += "\n" } else if original == nil { text += "\n" }
        let newData = Data(text.utf8)
        // Round-trip check of what we are about to write.
        guard (try? OrderedJSONParser.parse(newData)) == new else { throw ConfigError.verificationFailed("round-trip mismatch") }

        let url = resolvedURL
        var mode: mode_t = 0o600
        var st = stat()
        if stat(url.path, &st) == 0 { mode = st.st_mode & 0o777 }

        var backupPath: String? = nil
        if let o = original {
            try FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyyMMdd-HHmmss"
            let name = "settings.json.\(f.string(from: now)).\(tag).\(getpid()).bak"
            let b = backupsDir.appendingPathComponent(name)
            do { try SessionStore.atomicWrite(o, to: b, mode: 0o600) } catch { throw ConfigError.writeFailed("backup: \(error)") }
            backupPath = b.path
        } else {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }

        beforeCommit?()
        // Concurrent-modification check immediately before replacement.
        let current = try readBytes()
        guard current == original else { throw ConfigError.concurrentModification }
        do { try SessionStore.atomicWrite(newData, to: url, mode: mode) } catch { throw ConfigError.writeFailed("\(error)") }

        // Post-write verification.
        guard let written = try readBytes(), let parsed = try? OrderedJSONParser.parse(written), parsed == new else {
            throw ConfigError.verificationFailed("post-write content mismatch")
        }
        return backupPath
    }

    public static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

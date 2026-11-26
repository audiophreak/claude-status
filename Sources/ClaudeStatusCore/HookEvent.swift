import Foundation

/// Lifecycle events Claude Status registers for. Other documented events are accepted
/// (as `.other`) but never change session state.
public enum HookEventName: String, Codable, CaseIterable, Sendable {
    case sessionStart = "SessionStart"
    case userPromptSubmit = "UserPromptSubmit"
    case preToolUse = "PreToolUse"
    case postToolUse = "PostToolUse"
    case postToolUseFailure = "PostToolUseFailure"
    case permissionRequest = "PermissionRequest"
    case notification = "Notification"
    case stop = "Stop"
    case stopFailure = "StopFailure"
    case subagentStart = "SubagentStart"
    case subagentStop = "SubagentStop"
    case sessionEnd = "SessionEnd"

    /// Events registered in settings.json by the installer.
    public static let registered: [HookEventName] = HookEventName.allCases
}

/// A validated, minimised lifecycle event. Contains only the fields Claude Status needs:
/// no prompt text, tool input, tool output, transcript path or assistant messages.
public struct HookEvent: Equatable, Sendable {
    public var name: HookEventName?
    public var rawName: String
    public var sessionId: String
    public var timestamp: Double
    public var cwd: String?
    public var agentId: String?
    public var toolName: String?
    public var toolUseId: String?
    public var source: String?            // SessionStart
    public var reason: String?            // SessionEnd
    public var notificationType: String?  // Notification
    public var errorCategory: String?     // StopFailure
    public var isInterrupt: Bool          // PostToolUseFailure
    public var stopHookActive: Bool       // Stop
    public var backgroundTaskCount: Int?  // Stop
    public var promptId: String?

    public init(name: HookEventName?, rawName: String, sessionId: String, timestamp: Double,
                cwd: String? = nil, agentId: String? = nil, toolName: String? = nil,
                toolUseId: String? = nil, source: String? = nil, reason: String? = nil,
                notificationType: String? = nil, errorCategory: String? = nil,
                isInterrupt: Bool = false, stopHookActive: Bool = false,
                backgroundTaskCount: Int? = nil, promptId: String? = nil) {
        self.name = name; self.rawName = rawName; self.sessionId = sessionId
        self.timestamp = timestamp; self.cwd = cwd; self.agentId = agentId
        self.toolName = toolName; self.toolUseId = toolUseId; self.source = source
        self.reason = reason; self.notificationType = notificationType
        self.errorCategory = errorCategory; self.isInterrupt = isInterrupt
        self.stopHookActive = stopHookActive; self.backgroundTaskCount = backgroundTaskCount
        self.promptId = promptId
    }

    /// True when the hook fired inside a subagent (documented `agent_id` field).
    public var isSubagent: Bool { agentId != nil }
}

public enum HookEventParseError: Error, Equatable {
    case empty
    case tooLarge
    case malformedJSON
    case notAnObject
    case missingSessionId
    case invalidSessionId
    case missingEventName
    case invalidEventName
}

/// Strict validation helpers for untrusted strings.
public enum Validate {
    /// Session IDs are UUIDs in practice; accept a conservative superset.
    public static func sessionId(_ s: String) -> Bool {
        guard (1...128).contains(s.utf8.count) else { return false }
        return s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x2D || c == 0x5F
        }
    }

    /// Identifier-like token: letters, digits, `_ - . :` (tool names include `mcp__server__tool`).
    public static func token(_ s: String, maxLength: Int = 128) -> Bool {
        guard (1...maxLength).contains(s.utf8.count) else { return false }
        return s.utf8.allSatisfy { c in
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
                || c == 0x2D || c == 0x5F || c == 0x2E || c == 0x3A
        }
    }

    /// Absolute filesystem path without NUL or control characters, bounded length.
    public static func absolutePath(_ s: String) -> Bool {
        guard s.hasPrefix("/"), s.utf8.count <= 4096 else { return false }
        return !s.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}

public enum HookEventParser {
    /// Maximum payload fully parsed. Larger payloads (e.g. huge tool responses) fall back
    /// to a prefix scan for the few scalar fields Claude Status needs.
    public static let maxParsedBytes = 4 * 1024 * 1024
    public static let prefixScanBytes = 64 * 1024

    public static func parse(_ data: Data, timestamp: Double, truncated: Bool = false) throws -> HookEvent {
        guard !data.isEmpty else { throw HookEventParseError.empty }
        if truncated || data.count > maxParsedBytes {
            return try prefixScan(data.prefix(prefixScanBytes), timestamp: timestamp)
        }
        let obj: Any
        do {
            obj = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            throw HookEventParseError.malformedJSON
        }
        guard let dict = obj as? [String: Any] else { throw HookEventParseError.notAnObject }
        return try build(from: dict, timestamp: timestamp)
    }

    static func build(from d: [String: Any], timestamp: Double) throws -> HookEvent {
        guard let sidAny = d["session_id"] else { throw HookEventParseError.missingSessionId }
        guard let sid = sidAny as? String, Validate.sessionId(sid) else { throw HookEventParseError.invalidSessionId }
        guard let nameAny = d["hook_event_name"] else { throw HookEventParseError.missingEventName }
        guard let rawName = nameAny as? String, Validate.token(rawName, maxLength: 64) else {
            throw HookEventParseError.invalidEventName
        }
        func str(_ k: String, max: Int = 128) -> String? {
            guard let v = d[k] as? String, Validate.token(v, maxLength: max) else { return nil }
            return v
        }
        var cwd: String? = nil
        if let c = d["cwd"] as? String, Validate.absolutePath(c) { cwd = c }
        var bg: Int? = nil
        if let arr = d["background_tasks"] as? [Any] { bg = min(arr.count, 1000) }
        return HookEvent(
            name: HookEventName(rawValue: rawName),
            rawName: rawName,
            sessionId: sid,
            timestamp: timestamp,
            cwd: cwd,
            agentId: str("agent_id"),
            toolName: str("tool_name"),
            toolUseId: str("tool_use_id"),
            source: str("source", max: 32),
            reason: str("reason", max: 64),
            notificationType: str("notification_type", max: 64),
            errorCategory: str("error", max: 64),
            isInterrupt: (d["is_interrupt"] as? Bool) ?? false,
            stopHookActive: (d["stop_hook_active"] as? Bool) ?? false,
            backgroundTaskCount: bg,
            promptId: str("prompt_id")
        )
    }

    /// Fallback for oversized payloads: extract top-level-looking scalar string fields from
    /// the first bytes. Common fields precede tool payloads in Claude Code's JSON.
    static func prefixScan(_ data: Data, timestamp: Double) throws -> HookEvent {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data.dropLast(4), encoding: .utf8) else {
            throw HookEventParseError.malformedJSON
        }
        func field(_ key: String) -> String? {
            guard let r = text.range(of: "\"\(key)\"") else { return nil }
            var i = r.upperBound
            func skipWS() { while i < text.endIndex, text[i] == " " || text[i] == "\n" || text[i] == "\t" || text[i] == "\r" { i = text.index(after: i) } }
            skipWS()
            guard i < text.endIndex, text[i] == ":" else { return nil }
            i = text.index(after: i); skipWS()
            guard i < text.endIndex, text[i] == "\"" else { return nil }
            i = text.index(after: i)
            var out = ""
            while i < text.endIndex, text[i] != "\"", text[i] != "\\", out.count <= 4096 {
                out.append(text[i]); i = text.index(after: i)
            }
            guard i < text.endIndex, text[i] == "\"" else { return nil }
            return out
        }
        var dict: [String: Any] = [:]
        for k in ["session_id", "hook_event_name", "cwd", "agent_id", "tool_name", "tool_use_id", "prompt_id"] {
            if let v = field(k) { dict[k] = v }
        }
        return try build(from: dict, timestamp: timestamp)
    }
}

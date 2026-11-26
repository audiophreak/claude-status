import Foundation

/// Order-preserving JSON value used for editing `settings.json` without reordering keys or
/// reformatting numbers. Numbers keep their original text.
public indirect enum JSONValue: Equatable, Sendable {
    case object([(String, JSONValue)])
    case array([JSONValue])
    case string(String)
    case number(String)
    case bool(Bool)
    case null

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case let (.object(x), .object(y)):
            guard x.count == y.count else { return false }
            for (p, q) in zip(x, y) where p.0 != q.0 || p.1 != q.1 { return false }
            return true
        case let (.array(x), .array(y)): return x == y
        case let (.string(x), .string(y)): return x == y
        case let (.number(x), .number(y)): return x == y
        case let (.bool(x), .bool(y)): return x == y
        case (.null, .null): return true
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.last(where: { $0.0 == key })?.1
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { return a }; return nil }
    public var objectValue: [(String, JSONValue)]? { if case .object(let o) = self { return o }; return nil }
}

public enum JSONParseError: Error, Equatable {
    case tooLarge
    case tooDeep
    case invalid(offset: Int, message: String)
}

public struct OrderedJSONParser {
    public static let maxBytes = 4 * 1024 * 1024
    public static let maxDepth = 256

    private let bytes: [UInt8]
    private var i = 0

    public static func parse(_ data: Data) throws -> JSONValue {
        guard data.count <= maxBytes else { throw JSONParseError.tooLarge }
        var p = OrderedJSONParser(bytes: [UInt8](data))
        // Skip a UTF-8 BOM if present.
        if p.bytes.starts(with: [0xEF, 0xBB, 0xBF]) { p.i = 3 }
        p.ws()
        let v = try p.value(depth: 0)
        p.ws()
        guard p.i == p.bytes.count else { throw p.err("trailing content") }
        return v
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private func err(_ m: String) -> JSONParseError { .invalid(offset: i, message: m) }

    private mutating func ws() {
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x0A || bytes[i] == 0x0D || bytes[i] == 0x09 { i += 1 }
    }

    private mutating func value(depth: Int) throws -> JSONValue {
        guard depth < Self.maxDepth else { throw JSONParseError.tooDeep }
        guard i < bytes.count else { throw err("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try object(depth: depth)
        case UInt8(ascii: "["): return try array(depth: depth)
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return .number(try number())
        }
    }

    private mutating func literal(_ s: String) throws {
        let u = Array(s.utf8)
        guard i + u.count <= bytes.count, Array(bytes[i..<i + u.count]) == u else { throw err("invalid literal") }
        i += u.count
    }

    private mutating func object(depth: Int) throws -> JSONValue {
        i += 1; ws()
        var members: [(String, JSONValue)] = []
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
        while true {
            ws()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw err("expected key") }
            let k = try string()
            ws()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw err("expected ':'") }
            i += 1; ws()
            let v = try value(depth: depth + 1)
            members.append((k, v))
            ws()
            guard i < bytes.count else { throw err("unexpected end in object") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            throw err("expected ',' or '}'")
        }
    }

    private mutating func array(depth: Int) throws -> JSONValue {
        i += 1; ws()
        var items: [JSONValue] = []
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
        while true {
            ws()
            items.append(try value(depth: depth + 1))
            ws()
            guard i < bytes.count else { throw err("unexpected end in array") }
            if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
            if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            throw err("expected ',' or ']'")
        }
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw err("short unicode escape") }
        var v: UInt32 = 0
        for _ in 0..<4 {
            let c = bytes[i]; i += 1
            v <<= 4
            switch c {
            case 0x30...0x39: v |= UInt32(c - 0x30)
            case 0x41...0x46: v |= UInt32(c - 0x41 + 10)
            case 0x61...0x66: v |= UInt32(c - 0x61 + 10)
            default: throw err("bad hex digit")
            }
        }
        return v
    }

    private mutating func string() throws -> String {
        i += 1
        var out = [UInt8]()
        while true {
            guard i < bytes.count else { throw err("unterminated string") }
            let c = bytes[i]
            if c == UInt8(ascii: "\"") { i += 1; break }
            if c < 0x20 { throw err("control character in string") }
            if c == UInt8(ascii: "\\") {
                i += 1
                guard i < bytes.count else { throw err("bad escape") }
                let e = bytes[i]; i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var cp = try hex4()
                    if (0xD800...0xDBFF).contains(cp) {
                        guard i + 6 <= bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                            throw err("lone surrogate")
                        }
                        i += 2
                        let lo = try hex4()
                        guard (0xDC00...0xDFFF).contains(lo) else { throw err("bad surrogate pair") }
                        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
                    } else if (0xDC00...0xDFFF).contains(cp) {
                        throw err("lone surrogate")
                    }
                    guard let scalar = Unicode.Scalar(cp) else { throw err("bad code point") }
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default: throw err("bad escape")
                }
            } else {
                out.append(c); i += 1
            }
        }
        guard let s = String(bytes: out, encoding: .utf8) else { throw err("invalid UTF-8") }
        return s
    }

    private mutating func number() throws -> String {
        let start = i
        if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
        guard i < bytes.count else { throw err("bad number") }
        if bytes[i] == UInt8(ascii: "0") { i += 1 }
        else if (0x31...0x39).contains(bytes[i]) { while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 } }
        else { throw err("unexpected character") }
        if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
            i += 1
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw err("bad fraction") }
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
            i += 1
            if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, (0x30...0x39).contains(bytes[i]) else { throw err("bad exponent") }
            while i < bytes.count, (0x30...0x39).contains(bytes[i]) { i += 1 }
        }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }
}

/// Serialises like `JSON.stringify(value, null, 2)`, the format Claude Code writes.
public enum OrderedJSONWriter {
    public static func write(_ v: JSONValue, indent: Int = 2) -> String {
        var out = ""
        emit(v, level: 0, indent: indent, into: &out)
        return out
    }

    static func emit(_ v: JSONValue, level: Int, indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: (level + 1) * indent)
        let closePad = String(repeating: " ", count: level * indent)
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += quote(s)
        case .array(let a):
            if a.isEmpty { out += "[]"; return }
            out += "[\n"
            for (idx, item) in a.enumerated() {
                out += pad
                emit(item, level: level + 1, indent: indent, into: &out)
                out += idx == a.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "]"
        case .object(let o):
            if o.isEmpty { out += "{}"; return }
            out += "{\n"
            for (idx, (k, item)) in o.enumerated() {
                out += pad + quote(k) + ": "
                emit(item, level: level + 1, indent: indent, into: &out)
                out += idx == o.count - 1 ? "\n" : ",\n"
            }
            out += closePad + "}"
        }
    }

    public static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }
}

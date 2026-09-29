import Foundation

/// JSON coding helpers for the Actions service.
///
/// The service (a .NET/Newtonsoft stack) emits camelCase and accepts keys
/// case-insensitively. We encode camelCase (via explicit or synthesized keys) and
/// decode tolerant of PascalCase by lower-casing the first character of every key.
public enum ServiceJSON {
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            let last = path.last!.stringValue
            return AnyCodingKey(lowerFirst(last))
        }
        return d
    }

    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.withoutEscapingSlashes]
        return e
    }

    static func lowerFirst(_ s: String) -> String {
        guard let f = s.first, f.isUppercase else { return s }
        return f.lowercased() + s.dropFirst()
    }

    /// .NET round-trip ("O") timestamp: 7 fractional digits, UTC.
    public static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let base = f.string(from: date)  // e.g. 2024-01-01T00:00:00.123Z
        // Extend 3 fractional digits to 7.
        guard let dot = base.lastIndex(of: "."), let z = base.lastIndex(of: "Z") else { return base }
        let frac = base[base.index(after: dot)..<z]
        return String(base[..<dot]) + "." + frac + String(repeating: "0", count: max(0, 7 - frac.count)) + "Z"
    }

    /// Results-service timestamp: 3 fractional digits.
    public static func shortTimestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func parseTimestamp(_ s: String) -> Date? {
        // Trim fractional seconds to 3 digits for ISO8601DateFormatter.
        var str = s
        if let dot = str.lastIndex(of: ".") {
            let after = str.index(after: dot)
            var end = after
            while end < str.endIndex, str[end].isNumber { end = str.index(after: end) }
            let frac = str[after..<end]
            let trimmed = String(frac.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            str.replaceSubrange(after..<end, with: trimmed)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: str) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public struct AnyCodingKey: CodingKey {
    public var stringValue: String
    public var intValue: Int?
    public init(_ s: String) { stringValue = s; intValue = nil }
    public init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
    public init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

/// A loosely-typed JSON value, used for the parts of the protocol we pass through
/// untouched (agent properties, endpoint data, telemetry).
public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n):
            if n == n.rounded(), abs(n) < 1e15 { try c.encode(Int64(n)) } else { try c.encode(n) }
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o }; return nil }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let o) = self else { return nil }
        if let v = o[key] { return v }
        // case-insensitive fallback
        return o.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

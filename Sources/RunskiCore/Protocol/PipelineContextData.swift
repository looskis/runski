import Foundation

/// Compact JSON form of `PipelineContextData` (the `github`, `needs`, `matrix`,
/// `inputs`, `vars`, `strategy` contexts shipped inside a job message).
///
/// Scalars may appear bare; containers carry `t` (0 string, 1 array, 2 dictionary,
/// 3 bool, 4 number, 5 case-sensitive dictionary) with `s`/`a`/`d`/`b`/`n` payloads.
/// Dictionaries are ordered lists of `{k, v}` pairs.
public indirect enum ContextData: Equatable, Sendable {
    case string(String)
    case boolean(Bool)
    case number(Double)
    case null
    case array([ContextData])
    case dictionary([(key: String, value: ContextData)], caseSensitive: Bool)

    public static func == (lhs: ContextData, rhs: ContextData) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.null, .null): return true
        case (.array(let a), .array(let b)): return a == b
        case (.dictionary(let a, let ca), .dictionary(let b, let cb)):
            return ca == cb && a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public static func dict(_ pairs: [(String, ContextData)]) -> ContextData {
        .dictionary(pairs.map { (key: $0.0, value: $0.1) }, caseSensitive: false)
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public subscript(key: String) -> ContextData? {
        guard case .dictionary(let pairs, let cs) = self else { return nil }
        if cs { return pairs.first { $0.key == key }?.value }
        return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    /// Plain Swift representation (String / Bool / Double / NSNull / [Any] / ordered [String: Any]).
    public var plain: Any {
        switch self {
        case .string(let s): return s
        case .boolean(let b): return b
        case .number(let n): return n
        case .null: return NSNull()
        case .array(let a): return a.map(\.plain)
        case .dictionary(let pairs, _):
            var out: [String: Any] = [:]
            for p in pairs { out[p.key] = p.value.plain }
            return out
        }
    }
}

extension ContextData: Codable {
    private enum Keys: String, CodingKey { case t, s, a, d, b, n, k, v }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let b = try? single.decode(Bool.self) { self = .boolean(b); return }
        if let n = try? single.decode(Double.self) { self = .number(n); return }
        if let s = try? single.decode(String.self) { self = .string(s); return }

        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decodeIfPresent(Int.self, forKey: .t) ?? 0
        switch type {
        case 0: self = .string(try c.decodeIfPresent(String.self, forKey: .s) ?? "")
        case 1: self = .array(try c.decodeIfPresent([ContextData].self, forKey: .a) ?? [])
        case 2, 5:
            var pairs: [(key: String, value: ContextData)] = []
            if var arr = try? c.nestedUnkeyedContainer(forKey: .d) {
                while !arr.isAtEnd {
                    let pair = try arr.nestedContainer(keyedBy: Keys.self)
                    let k = try pair.decode(String.self, forKey: .k)
                    let v = try pair.decodeIfPresent(ContextData.self, forKey: .v) ?? .null
                    pairs.append((k, v))
                }
            }
            self = .dictionary(pairs, caseSensitive: type == 5)
        case 3: self = .boolean(try c.decodeIfPresent(Bool.self, forKey: .b) ?? false)
        case 4: self = .number(try c.decodeIfPresent(Double.self, forKey: .n) ?? 0)
        default:
            throw DecodingError.dataCorruptedError(forKey: .t, in: c, debugDescription: "unknown context data type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let s):
            var c = encoder.singleValueContainer(); try c.encode(s)
        case .boolean(let b):
            var c = encoder.singleValueContainer(); try c.encode(b)
        case .number(let n):
            var c = encoder.singleValueContainer(); try c.encode(n)
        case .null:
            var c = encoder.singleValueContainer(); try c.encodeNil()
        case .array(let items):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(1, forKey: .t)
            if !items.isEmpty { try c.encode(items, forKey: .a) }
        case .dictionary(let pairs, let cs):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(cs ? 5 : 2, forKey: .t)
            if !pairs.isEmpty {
                var arr = c.nestedUnkeyedContainer(forKey: .d)
                for p in pairs {
                    var pc = arr.nestedContainer(keyedBy: Keys.self)
                    try pc.encode(p.key, forKey: .k)
                    try pc.encode(p.value, forKey: .v)
                }
            }
        }
    }
}

import Foundation

/// Compact JSON form of the Actions service `TemplateToken` tree.
///
/// A bare JSON string/bool/number/null is a scalar token; objects carry `type`
/// (0 string, 1 sequence, 2 mapping, 3 basic expression, 4 insert expression,
/// 5 boolean, 6 number, 7 null) plus `file`/`line`/`col` for diagnostics.
public indirect enum TemplateToken: Equatable, Sendable {
    case string(String)
    case boolean(Bool)
    case number(Double)
    case null
    /// `${{ expr }}` where the whole scalar is one expression.
    case expression(String)
    /// `${{ insert }}` directive inside a mapping key.
    case insert
    case sequence([TemplateToken])
    case mapping([(key: TemplateToken, value: TemplateToken)])

    public static func == (lhs: TemplateToken, rhs: TemplateToken) -> Bool {
        switch (lhs, rhs) {
        case (.string(let a), .string(let b)): return a == b
        case (.boolean(let a), .boolean(let b)): return a == b
        case (.number(let a), .number(let b)): return a == b
        case (.null, .null), (.insert, .insert): return true
        case (.expression(let a), .expression(let b)): return a == b
        case (.sequence(let a), .sequence(let b)): return a == b
        case (.mapping(let a), .mapping(let b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.key == $1.key && $0.value == $1.value }
        default: return false
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var isScalar: Bool {
        switch self {
        case .sequence, .mapping: return false
        default: return true
        }
    }

    /// Look up a mapping entry by literal key (case-insensitive, matching the runner).
    public subscript(key: String) -> TemplateToken? {
        guard case .mapping(let pairs) = self else { return nil }
        return pairs.first { $0.key.stringValue?.caseInsensitiveCompare(key) == .orderedSame }?.value
    }
}

extension TemplateToken: Codable {
    private enum Keys: String, CodingKey {
        case type, file, line, col, lit, expr, directive, seq, map, bool, num, key, value
    }

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() { self = .null; return }
        if let b = try? single.decode(Bool.self) { self = .boolean(b); return }
        if let n = try? single.decode(Double.self) { self = .number(n); return }
        if let s = try? single.decode(String.self) { self = .string(s); return }

        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decodeIfPresent(Int.self, forKey: .type) ?? 0
        switch type {
        case 0: self = .string(try c.decodeIfPresent(String.self, forKey: .lit) ?? "")
        case 1: self = .sequence(try c.decodeIfPresent([TemplateToken].self, forKey: .seq) ?? [])
        case 2:
            var pairs: [(key: TemplateToken, value: TemplateToken)] = []
            if var arr = try? c.nestedUnkeyedContainer(forKey: .map) {
                while !arr.isAtEnd {
                    let pair = try arr.nestedContainer(keyedBy: Keys.self)
                    let k = try pair.decode(TemplateToken.self, forKey: .key)
                    let v = try pair.decode(TemplateToken.self, forKey: .value)
                    pairs.append((k, v))
                }
            }
            self = .mapping(pairs)
        case 3: self = .expression(try c.decodeIfPresent(String.self, forKey: .expr) ?? "")
        case 4: self = .insert
        case 5: self = .boolean(try c.decodeIfPresent(Bool.self, forKey: .bool) ?? false)
        case 6: self = .number(try c.decodeIfPresent(Double.self, forKey: .num) ?? 0)
        case 7: self = .null
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown TemplateToken type \(type)")
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
        case .expression(let e):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(3, forKey: .type); try c.encode(e, forKey: .expr)
        case .insert:
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(4, forKey: .type); try c.encode("insert", forKey: .directive)
        case .sequence(let items):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(1, forKey: .type); try c.encode(items, forKey: .seq)
        case .mapping(let pairs):
            var c = encoder.container(keyedBy: Keys.self)
            try c.encode(2, forKey: .type)
            var arr = c.nestedUnkeyedContainer(forKey: .map)
            for p in pairs {
                var pc = arr.nestedContainer(keyedBy: Keys.self)
                try pc.encode(p.key, forKey: .key)
                try pc.encode(p.value, forKey: .value)
            }
        }
    }
}

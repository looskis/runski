import Foundation

/// A GitHub Actions expression value. Containers are reference types so that
/// `==` on arrays/objects can implement the runner's identity semantics.
public enum ExprValue: CustomStringConvertible, @unchecked Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array(ExprArray)
    case object(ExprObject)

    public final class ExprArray: @unchecked Sendable {
        public var items: [ExprValue]
        /// Result of a `.*` wildcard: further indexing applies to each element.
        public let isFiltered: Bool
        public init(_ items: [ExprValue] = [], filtered: Bool = false) { self.items = items; self.isFiltered = filtered }
    }

    public final class ExprObject: @unchecked Sendable {
        public private(set) var pairs: [(key: String, value: ExprValue)]
        public let caseSensitive: Bool
        public init(_ pairs: [(String, ExprValue)] = [], caseSensitive: Bool = false) {
            self.pairs = []
            self.caseSensitive = caseSensitive
            for (k, v) in pairs { self[k] = v }
        }
        public subscript(key: String) -> ExprValue? {
            get {
                if caseSensitive { return pairs.first { $0.key == key }?.value }
                return pairs.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
            }
            set {
                let idx = caseSensitive ? pairs.firstIndex { $0.key == key }
                                        : pairs.firstIndex { $0.key.caseInsensitiveCompare(key) == .orderedSame }
                if let idx {
                    if let newValue { pairs[idx].value = newValue } else { pairs.remove(at: idx) }
                } else if let newValue {
                    pairs.append((key, newValue))
                }
            }
        }
        public var keys: [String] { pairs.map(\.key) }
    }

    public static func obj(_ pairs: [(String, ExprValue)] = [], caseSensitive: Bool = false) -> ExprValue {
        .object(ExprObject(pairs, caseSensitive: caseSensitive))
    }
    public static func arr(_ items: [ExprValue]) -> ExprValue { .array(ExprArray(items)) }
    public static func str(_ s: String) -> ExprValue { .string(s) }

    public var isPrimitive: Bool {
        switch self {
        case .array, .object: return false
        default: return true
        }
    }

    /// The runner's `IsFalsy`.
    public var isTruthy: Bool {
        switch self {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return !(n == 0 || n.isNaN)
        case .string(let s): return !s.isEmpty
        case .array, .object: return true
        }
    }

    public var kindName: String {
        switch self {
        case .null: return "Null"
        case .bool: return "Boolean"
        case .number: return "Number"
        case .string: return "String"
        case .array: return "Array"
        case .object: return "Object"
        }
    }

    public var description: String { asString }

    /// `ConvertToString`: null → "", bool → true/false, number → G15, containers → "Array"/"Object".
    public var asString: String {
        switch self {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return ExprValue.formatNumber(n)
        case .string(let s): return s
        case .array: return "Array"
        case .object: return "Object"
        }
    }

    /// `ConvertToNumber`.
    public var asNumber: Double {
        switch self {
        case .null: return 0
        case .bool(let b): return b ? 1 : 0
        case .number(let n): return n
        case .string(let s): return ExprValue.parseNumber(s)
        case .array, .object: return .nan
        }
    }

    public var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    public var objectValue: ExprObject? { if case .object(let o) = self { return o }; return nil }
    public var arrayValue: ExprArray? { if case .array(let a) = self { return a }; return nil }

    // MARK: Number formatting (.NET "G15", invariant culture)

    public static func formatNumber(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
        if n == 0 { return "0" }
        if n == n.rounded(), abs(n) < 1e15 { return String(Int64(n)) }
        var s = String(format: "%.15g", n)
        if let e = s.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var mantissa = String(s[..<e])
            var exp = String(s[s.index(after: e)...])
            if mantissa.contains(".") {
                while mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
            }
            let sign = exp.hasPrefix("-") ? "-" : "+"
            exp = exp.trimmingCharacters(in: CharacterSet(charactersIn: "+-"))
            while exp.hasPrefix("0"), exp.count > 2 { exp.removeFirst() }
            if exp.count < 2 { exp = "0" + exp }
            s = mantissa + "E" + sign + exp
        } else if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s
    }

    /// `ExpressionUtility.ParseNumber` (JavaScript-like `Number()` semantics).
    public static func parseNumber(_ raw: String) -> Double {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return 0 }
        if s == "Infinity" { return .infinity }
        if s == "-Infinity" { return -.infinity }
        if s.caseInsensitiveCompare("nan") == .orderedSame { return .nan }
        if s.caseInsensitiveCompare("infinity") == .orderedSame { return .infinity }
        if s.caseInsensitiveCompare("-infinity") == .orderedSame { return -.infinity }
        if s.hasPrefix("0x"), s.count > 2 {
            let hex = s.dropFirst(2)
            guard hex.allSatisfy({ $0.isHexDigit }), let v = UInt32(hex, radix: 16) else { return .nan }
            return Double(Int32(bitPattern: v))
        }
        if s.hasPrefix("0o"), s.count > 2 {
            let oct = s.dropFirst(2)
            guard oct.allSatisfy({ "01234567".contains($0) }), let v = UInt32(oct, radix: 8) else { return .nan }
            return Double(Int32(bitPattern: v))
        }
        // Double.TryParse(NumberStyles.Float-ish): sign, digits, optional fraction, optional exponent.
        let pattern = "^[+-]?(\\d+\\.?\\d*|\\.\\d+)([eE][+-]?\\d+)?$"
        guard s.range(of: pattern, options: .regularExpression) != nil, let d = Double(s.hasPrefix("+") ? String(s.dropFirst()) : s) else {
            // Double(String) rejects "1." — handle it.
            if s.hasSuffix("."), let d = Double(String(s.dropLast())) { return d }
            return .nan
        }
        return d
    }

    // MARK: Comparison

    /// `CoerceTypes` + `==` semantics.
    public static func looseEquals(_ a: ExprValue, _ b: ExprValue) -> Bool {
        let (l, r) = coerce(a, b)
        switch (l, r) {
        case (.null, .null): return true
        case (.number(let x), .number(let y)): return x == y   // NaN != NaN
        case (.string(let x), .string(let y)): return x.caseInsensitiveCompare(y) == .orderedSame
        case (.bool(let x), .bool(let y)): return x == y
        case (.array(let x), .array(let y)): return x === y
        case (.object(let x), .object(let y)): return x === y
        default: return false
        }
    }

    public static func compare(_ a: ExprValue, _ b: ExprValue) -> ComparisonResult? {
        let (l, r) = coerce(a, b)
        switch (l, r) {
        case (.number(let x), .number(let y)):
            if x.isNaN || y.isNaN { return nil }
            return x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
        case (.string(let x), .string(let y)):
            let ux = x.uppercased(), uy = y.uppercased()
            if ux == uy { return .orderedSame }
            return ux.utf16.lexicographicallyPrecedes(uy.utf16) ? .orderedAscending : .orderedDescending
        case (.bool(let x), .bool(let y)):
            if x == y { return .orderedSame }
            return (!x && y) ? .orderedAscending : .orderedDescending
        default: return nil
        }
    }

    private static func coerce(_ a: ExprValue, _ b: ExprValue) -> (ExprValue, ExprValue) {
        var l = a, r = b
        for _ in 0..<4 {
            if l.kindName == r.kindName { return (l, r) }
            switch (l, r) {
            case (.number, .string): r = .number(r.asNumber)
            case (.string, .number): l = .number(l.asNumber)
            case (.bool, _), (.null, _): l = .number(l.asNumber)
            case (_, .bool), (_, .null): r = .number(r.asNumber)
            default: return (l, r)
            }
        }
        return (l, r)
    }

    // MARK: JSON

    public func toJSON() -> String {
        var out = ""
        ExprValue.writeJSON(self, indent: 0, into: &out)
        return out
    }

    private static func writeJSON(_ v: ExprValue, indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: indent)
        switch v {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += formatNumber(n)
        case .string(let s): out += jsonString(s)
        case .array(let a):
            if a.items.isEmpty { out += "[]"; return }
            out += "[\n"
            for (i, item) in a.items.enumerated() {
                out += pad + "  "
                writeJSON(item, indent: indent + 2, into: &out)
                out += i == a.items.count - 1 ? "\n" : ",\n"
            }
            out += pad + "]"
        case .object(let o):
            if o.pairs.isEmpty { out += "{}"; return }
            out += "{\n"
            for (i, p) in o.pairs.enumerated() {
                out += pad + "  " + jsonString(p.key) + ": "
                writeJSON(p.value, indent: indent + 2, into: &out)
                out += i == o.pairs.count - 1 ? "\n" : ",\n"
            }
            out += pad + "}"
        }
    }

    static func jsonString(_ s: String) -> String {
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
                if u.value < 0x20 || u.value == 0x85 || u.value == 0x2028 || u.value == 0x2029 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    public static func fromJSON(_ text: String) throws -> ExprValue {
        let data = Data(text.utf8)
        let obj = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        return fromFoundation(obj)
    }

    public static func fromFoundation(_ any: Any) -> ExprValue {
        switch any {
        case is NSNull: return .null
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.doubleValue)
        case let s as String: return .string(s)
        case let a as [Any]: return .arr(a.map(fromFoundation))
        case let d as [String: Any]:
            // JSONSerialization loses key order; sort for determinism.
            return .obj(d.keys.sorted().map { ($0, fromFoundation(d[$0]!)) })
        default: return .string(String(describing: any))
        }
    }

    public static func from(_ ctx: ContextData) -> ExprValue {
        switch ctx {
        case .string(let s): return .string(s)
        case .boolean(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .null: return .null
        case .array(let a): return .arr(a.map(from))
        case .dictionary(let pairs, let cs): return .obj(pairs.map { ($0.key, from($0.value)) }, caseSensitive: cs)
        }
    }

    public func toContextData() -> ContextData {
        switch self {
        case .null: return .null
        case .bool(let b): return .boolean(b)
        case .number(let n): return .number(n)
        case .string(let s): return .string(s)
        case .array(let a): return .array(a.items.map { $0.toContextData() })
        case .object(let o): return .dictionary(o.pairs.map { (key: $0.key, value: $0.value.toContextData()) }, caseSensitive: o.caseSensitive)
        }
    }
}

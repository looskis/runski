import Foundation

/// Supplies named values (`github`, `steps`, …) and extension functions to the evaluator.
public struct ExpressionContext {
    public var values: [String: ExprValue]
    /// Extension functions such as `success()` / `hashFiles()`.
    public var functions: [String: ([ExprValue]) throws -> ExprValue]

    public init(values: [String: ExprValue] = [:], functions: [String: ([ExprValue]) throws -> ExprValue] = [:]) {
        self.values = [:]
        for (k, v) in values { self.values[k.lowercased()] = v }
        self.functions = [:]
        for (k, v) in functions { self.functions[k.lowercased()] = v }
    }

    public subscript(name: String) -> ExprValue? {
        get { values[name.lowercased()] }
        set { values[name.lowercased()] = newValue }
    }

    public mutating func setFunction(_ name: String, _ f: @escaping ([ExprValue]) throws -> ExprValue) {
        functions[name.lowercased()] = f
    }

    public var namedValueSet: Set<String> { Set(values.keys) }
}

public enum Expression {
    /// Parse + evaluate a bare expression (no `${{ }}` delimiters).
    public static func evaluate(_ source: String, context: ExpressionContext) throws -> ExprValue {
        guard let node = try ExpressionParser.parse(source, allowedNamedValues: context.namedValueSet) else {
            throw ExpressionError("An expression was expected", expression: source)
        }
        return try Evaluator(context: context).eval(node)
    }

    /// Evaluate a step/job `if:` condition string as sent by the service.
    public static func evaluateCondition(_ source: String, context: ExpressionContext) throws -> Bool {
        let s = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return try evaluate("success()", context: context).isTruthy }
        return try evaluate(s, context: context).isTruthy
    }

    /// Apply the service's `ConvertToIfCondition` rewrite (used for composite-action steps).
    public static func normalizeCondition(_ raw: String?) throws -> String {
        var s = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("${{"), s.hasSuffix("}}"), s.range(of: "${{", range: s.index(s.startIndex, offsetBy: 3)..<s.endIndex) == nil {
            s = String(s.dropFirst(3).dropLast(2)).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if s.contains("${{") {
            s = try TemplateScalar.parse(s).rewrittenExpression ?? s
        }
        if s.isEmpty { return "success()" }
        let node = try ExpressionParser.parse(s)
        if node?.containsStatusFunction == true { return s }
        return "success() && (\(s))"
    }
}

struct Evaluator {
    let context: ExpressionContext

    func eval(_ node: ExprNode) throws -> ExprValue {
        switch node {
        case .literal(let v): return v
        case .namedValue(let name): return context[name] ?? .null
        case .not(let inner): return .bool(!(try eval(inner).isTruthy))
        case .and(let items):
            var last: ExprValue = .null
            for it in items { last = try eval(it); if !last.isTruthy { return last } }
            return last
        case .or(let items):
            var last: ExprValue = .null
            for it in items { last = try eval(it); if last.isTruthy { return last } }
            return last
        case .binary(let op, let l, let r):
            let a = try eval(l), b = try eval(r)
            switch op {
            case "==": return .bool(ExprValue.looseEquals(a, b))
            case "!=": return .bool(!ExprValue.looseEquals(a, b))
            case "<": return .bool(ExprValue.compare(a, b) == .orderedAscending)
            case ">": return .bool(ExprValue.compare(a, b) == .orderedDescending)
            case "<=":
                let c = ExprValue.compare(a, b); return .bool(c == .orderedAscending || c == .orderedSame)
            case ">=":
                let c = ExprValue.compare(a, b); return .bool(c == .orderedDescending || c == .orderedSame)
            default: throw ExpressionError("unknown operator \(op)")
            }
        case .index(let target, let idxNode):
            let t = try eval(target)
            let idx = try eval(idxNode)
            return index(t, idx)
        case .wildcard(let target):
            let t = try eval(target)
            return wildcard(t)
        case .function(let name, let argNodes):
            return try callFunction(name, argNodes)
        }
    }

    // MARK: Index / wildcard

    private func index(_ target: ExprValue, _ idx: ExprValue) -> ExprValue {
        switch target {
        case .object(let o):
            guard idx.isPrimitive else { return .null }
            return o[idx.asString] ?? .null
        case .array(let a):
            if a.isFiltered {
                // filtered array: apply per element
                var out: [ExprValue] = []
                for el in a.items {
                    switch el {
                    case .object(let o):
                        if idx.isPrimitive, let v = o[idx.asString] { out.append(v) }
                    case .array(let inner):
                        if let i = arrayIndex(idx, count: inner.items.count) { out.append(inner.items[i]) }
                    default: break
                    }
                }
                return makeFiltered(out)
            }
            guard let i = arrayIndex(idx, count: a.items.count) else { return .null }
            return a.items[i]
        default:
            return .null
        }
    }

    private func arrayIndex(_ idx: ExprValue, count: Int) -> Int? {
        let n = idx.asNumber
        guard !n.isNaN, n >= 0, n <= Double(Int32.max) else { return nil }
        let i = Int(n.rounded(.down))
        return i < count ? i : nil
    }

    private func makeFiltered(_ items: [ExprValue]) -> ExprValue {
        .array(ExprValue.ExprArray(items, filtered: true))
    }

    private func wildcard(_ target: ExprValue) -> ExprValue {
        switch target {
        case .object(let o): return makeFiltered(o.pairs.map(\.value))
        case .array(let a):
            if a.isFiltered {
                var out: [ExprValue] = []
                for el in a.items {
                    switch el {
                    case .object(let o): out.append(contentsOf: o.pairs.map(\.value))
                    case .array(let inner): out.append(contentsOf: inner.items)
                    default: break
                    }
                }
                return makeFiltered(out)
            }
            return makeFiltered(a.items)
        default: return makeFiltered([])
        }
    }

    // MARK: Functions

    private func callFunction(_ name: String, _ argNodes: [ExprNode]) throws -> ExprValue {
        let lname = name.lowercased()
        if let custom = context.functions[lname] {
            return try custom(try argNodes.map(eval))
        }
        switch lname {
        case "contains":
            let search = try eval(argNodes[0])
            switch search {
            case .array(let a):
                guard !a.items.isEmpty else { return .bool(false) }
                let item = try eval(argNodes[1])
                return .bool(a.items.contains { ExprValue.looseEquals($0, item) })
            case .object: return .bool(false)
            default:
                let item = try eval(argNodes[1])
                guard item.isPrimitive else { return .bool(false) }
                return .bool(search.asString.range(of: item.asString, options: .caseInsensitive) != nil || item.asString.isEmpty)
            }
        case "startswith", "endswith":
            let a = try eval(argNodes[0]), b = try eval(argNodes[1])
            guard a.isPrimitive, b.isPrimitive else { return .bool(false) }
            let s = a.asString.uppercased(), p = b.asString.uppercased()
            return .bool(lname == "startswith" ? s.hasPrefix(p) : s.hasSuffix(p))
        case "format":
            return .string(try format(argNodes))
        case "join":
            let x = try eval(argNodes[0])
            switch x {
            case .array(let a):
                if a.items.isEmpty { return .string("") }
                var sep = ","
                if argNodes.count > 1, a.items.count > 1 {
                    let s = try eval(argNodes[1])
                    if s.isPrimitive { sep = s.asString }
                }
                return .string(a.items.map(\.asString).joined(separator: sep))
            case .object: return .string("")
            default: return .string(x.asString)
            }
        case "tojson":
            return .string(try eval(argNodes[0]).toJSON())
        case "fromjson":
            let s = try eval(argNodes[0]).asString
            do { return try ExprValue.fromJSON(s) }
            catch { throw ExpressionError("Error parsing fromJson input. Error: \(error.localizedDescription). Input: \(s)") }
        case "case":
            var i = 0
            while i + 1 < argNodes.count {
                let pred = try eval(argNodes[i])
                guard case .bool(let b) = pred else { throw ExpressionError("case predicate must evaluate to a boolean value") }
                if b { return try eval(argNodes[i + 1]) }
                i += 2
            }
            return try eval(argNodes[argNodes.count - 1])
        case "always": return .bool(true)
        case "success", "failure", "cancelled":
            // Default stubs when the worker hasn't supplied real ones.
            return .null
        case "hashfiles":
            return .null
        default:
            throw ExpressionError("Unrecognized function: '\(name)'")
        }
    }

    private func format(_ argNodes: [ExprNode]) throws -> String {
        let fmt = try eval(argNodes[0]).asString
        let chars = Array(fmt)
        var out = ""
        var i = 0
        var cache: [Int: ExprValue] = [:]
        func arg(_ n: Int) throws -> ExprValue {
            if let c = cache[n] { return c }
            let v = try eval(argNodes[n + 1])
            cache[n] = v
            return v
        }
        while i < chars.count {
            let c = chars[i]
            if c == "{" {
                if i + 1 < chars.count, chars[i + 1] == "{" { out.append("{"); i += 2; continue }
                var j = i + 1
                var digits = ""
                while j < chars.count, chars[j].isNumber { digits.append(chars[j]); j += 1 }
                guard !digits.isEmpty, let n = Int(digits), n <= 255 else {
                    throw ExpressionError("The following format string is invalid: \(fmt)")
                }
                var spec = ""
                if j < chars.count, chars[j] == ":" {
                    j += 1
                    while j < chars.count, chars[j] != "}" {
                        if chars[j] == "}", j + 1 < chars.count, chars[j + 1] == "}" { spec.append("}"); j += 2; continue }
                        spec.append(chars[j]); j += 1
                    }
                }
                guard j < chars.count, chars[j] == "}" else { throw ExpressionError("The following format string is invalid: \(fmt)") }
                guard n < argNodes.count - 1 else {
                    throw ExpressionError("The following format string references more arguments than were supplied: \(fmt)")
                }
                let v = try arg(n)
                if !spec.isEmpty { throw ExpressionError("The format specifiers '\(spec)' are not valid for objects of type '\(v.kindName)'") }
                out += v.asString
                i = j + 1
            } else if c == "}" {
                if i + 1 < chars.count, chars[i + 1] == "}" { out.append("}"); i += 2; continue }
                throw ExpressionError("The following format string is invalid: \(fmt)")
            } else {
                out.append(c); i += 1
            }
        }
        return out
    }
}

import Foundation

/// Parsing of `${{ }}` inside YAML scalars (action.yml, composite steps) into the
/// same shape the service sends: a single expression keeps its type, a mixed
/// string becomes `format('…{0}…', expr)`.
public struct TemplateScalar {
    public let token: TemplateToken
    /// For mixed strings, the synthesized `format(...)` expression.
    public var rewrittenExpression: String? {
        if case .expression(let e) = token { return e }
        return nil
    }

    public static func parse(_ s: String) throws -> TemplateScalar {
        guard s.contains("${{") else { return TemplateScalar(token: .string(s)) }
        var segments: [(literal: String?, expr: String?)] = []
        let chars = Array(s)
        var i = 0
        var lit = ""
        while i < chars.count {
            if i + 2 < chars.count, chars[i] == "$", chars[i + 1] == "{", chars[i + 2] == "{" {
                var j = i + 3
                var inString = false
                var expr = ""
                var closed = false
                while j < chars.count {
                    let c = chars[j]
                    if c == "'" { inString.toggle() }
                    if !inString, c == "}", j + 1 < chars.count, chars[j + 1] == "}" { closed = true; break }
                    expr.append(c); j += 1
                }
                guard closed else {
                    throw ExpressionError("The expression is not closed. An unescaped ${{ sequence was found, but the closing }} sequence was not found.")
                }
                let trimmed = expr.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { throw ExpressionError("An expression was expected") }
                if !lit.isEmpty { segments.append((lit, nil)); lit = "" }
                segments.append((nil, trimmed))
                i = j + 2
            } else {
                lit.append(chars[i]); i += 1
            }
        }
        if !lit.isEmpty { segments.append((lit, nil)) }

        if segments.count == 1, let e = segments[0].expr {
            // A lone string literal expression is just a string.
            if let node = try ExpressionParser.parse(e), case .literal(.string(let str)) = node {
                return TemplateScalar(token: .string(str))
            }
            return TemplateScalar(token: .expression(e))
        }
        var fmt = "'"
        var args: [String] = []
        for seg in segments {
            if let l = seg.literal {
                fmt += l.replacingOccurrences(of: "'", with: "''").replacingOccurrences(of: "{", with: "{{").replacingOccurrences(of: "}", with: "}}")
            } else if let e = seg.expr {
                fmt += "{\(args.count)}"
                args.append(e)
            }
        }
        fmt += "'"
        return TemplateScalar(token: .expression("format(\(fmt)\(args.map { ", " + $0 }.joined()))"))
    }
}

public enum TemplateEvaluator {
    /// Evaluate a token tree to an expression value.
    public static func evaluate(_ token: TemplateToken, context: ExpressionContext) throws -> ExprValue {
        switch token {
        case .string(let s): return .string(s)
        case .boolean(let b): return .bool(b)
        case .number(let n): return .number(n)
        case .null: return .null
        case .insert: throw ExpressionError("insert directive is only valid as a mapping key")
        case .expression(let e): return try Expression.evaluate(e, context: context)
        case .sequence(let items): return .arr(try items.map { try evaluate($0, context: context) })
        case .mapping(let pairs):
            let obj = ExprValue.ExprObject()
            for p in pairs {
                if case .insert = p.key {
                    let v = try evaluate(p.value, context: context)
                    if case .object(let o) = v { for q in o.pairs { obj[q.key] = q.value } }
                    continue
                }
                let k = try evaluate(p.key, context: context).asString
                obj[k] = try evaluate(p.value, context: context)
            }
            return .object(obj)
        }
    }

    /// Evaluate to a string (scalar tokens only; containers are an error).
    public static func evaluateString(_ token: TemplateToken?, context: ExpressionContext) throws -> String? {
        guard let token else { return nil }
        let v = try evaluate(token, context: context)
        switch v {
        case .array, .object: throw ExpressionError("Expected a scalar value but got \(v.kindName)")
        default: return v.asString
        }
    }

    public static func evaluateBool(_ token: TemplateToken?, context: ExpressionContext) throws -> Bool? {
        guard let token else { return nil }
        let v = try evaluate(token, context: context)
        switch v {
        case .bool(let b): return b
        case .string(let s):
            if s.caseInsensitiveCompare("true") == .orderedSame { return true }
            if s.caseInsensitiveCompare("false") == .orderedSame { return false }
            throw ExpressionError("Expected a boolean but got '\(s)'")
        case .null: return nil
        default: return v.isTruthy
        }
    }

    public static func evaluateNumber(_ token: TemplateToken?, context: ExpressionContext) throws -> Double? {
        guard let token else { return nil }
        let v = try evaluate(token, context: context)
        switch v {
        case .number(let n): return n
        case .string(let s):
            let n = ExprValue.parseNumber(s)
            if n.isNaN { throw ExpressionError("Expected a number but got '\(s)'") }
            return n
        case .null: return nil
        default: throw ExpressionError("Expected a number but got \(v.kindName)")
        }
    }

    /// Evaluate a mapping token to an ordered string dictionary (step `with:` / `env:`).
    public static func evaluateStringMap(_ token: TemplateToken?, context: ExpressionContext) throws -> [(String, String)] {
        guard let token else { return [] }
        let v = try evaluate(token, context: context)
        guard case .object(let o) = v else {
            if case .null = v { return [] }
            throw ExpressionError("Expected a mapping but got \(v.kindName)")
        }
        return try o.pairs.map { p in
            switch p.value {
            case .array, .object: throw ExpressionError("Expected a scalar value for '\(p.key)' but got \(p.value.kindName)")
            default: return (p.key, p.value.asString)
            }
        }
    }

    /// Convert a YAML-derived value (from Yams) into a TemplateToken, parsing `${{ }}`.
    public static func token(fromYAML any: Any?) throws -> TemplateToken {
        switch any {
        case nil, is NSNull: return .null
        case let b as Bool: return .boolean(b)
        case let i as Int: return .number(Double(i))
        case let d as Double: return .number(d)
        case let s as String: return try TemplateScalar.parse(s).token
        case let a as [Any]: return .sequence(try a.map { try token(fromYAML: $0) })
        case let d as [String: Any]:
            return .mapping(try d.keys.sorted().map { k in
                let key: TemplateToken = k.trimmingCharacters(in: .whitespaces) == "${{ insert }}" ? .insert : .string(k)
                return (key: key, value: try token(fromYAML: d[k]!))
            })
        case let d as [AnyHashable: Any]:
            return .mapping(try d.map { (key: .string(String(describing: $0.key)), value: try token(fromYAML: $0.value)) })
        default: return .string(String(describing: any!))
        }
    }
}

import Foundation

public struct ExpressionError: Error, CustomStringConvertible {
    public let message: String
    public let expression: String?
    public init(_ message: String, expression: String? = nil) {
        self.message = message
        self.expression = expression
    }
    public var description: String {
        if let e = expression { return "\(message) within expression: \(e)" }
        return message
    }
}

public indirect enum ExprNode: Sendable {
    case literal(ExprValue)
    case namedValue(String)
    case function(String, [ExprNode])
    case index(ExprNode, ExprNode)          // a[b], a.b (b is a string literal)
    case wildcard(ExprNode)                 // a.* / a[*]
    case not(ExprNode)
    case and([ExprNode])
    case or([ExprNode])
    case binary(String, ExprNode, ExprNode) // == != < <= > >=

    /// True when any status function appears anywhere in the tree.
    public var containsStatusFunction: Bool {
        switch self {
        case .function(let name, let args):
            if ["success", "failure", "cancelled", "always"].contains(name.lowercased()) { return true }
            return args.contains { $0.containsStatusFunction }
        case .index(let a, let b): return a.containsStatusFunction || b.containsStatusFunction
        case .wildcard(let a), .not(let a): return a.containsStatusFunction
        case .and(let xs), .or(let xs): return xs.contains { $0.containsStatusFunction }
        case .binary(_, let a, let b): return a.containsStatusFunction || b.containsStatusFunction
        default: return false
        }
    }
}

enum Token: Equatable {
    case number(Double)
    case string(String)
    case null, `true`, `false`
    case ident(String)
    case lparen, rparen, lbracket, rbracket, comma, dot, star
    case not, and, or, eq, neq, lt, lte, gt, gte
    case end
}

struct Lexer {
    let text: [Character]
    var pos = 0
    let source: String

    init(_ s: String) { text = Array(s); source = s }

    static let boundary: Set<Character> = ["(", "[", ")", "]", ",", ".", "!", ">", "<", "=", "&", "|", " ", "\t", "\n", "\r"]

    mutating func tokenize() throws -> [(Token, Int)] {
        var out: [(Token, Int)] = []
        while true {
            while pos < text.count, text[pos].isWhitespace { pos += 1 }
            guard pos < text.count else { out.append((.end, pos)); return out }
            let start = pos
            let c = text[pos]
            let prev = out.last?.0
            func tok(_ t: Token) { out.append((t, start)); pos += 1 }
            switch c {
            case "(": tok(.lparen)
            case ")": tok(.rparen)
            case "[": tok(.lbracket)
            case "]": tok(.rbracket)
            case ",": tok(.comma)
            case "*": tok(.star)
            case "'":
                pos += 1
                var s = ""
                var closed = false
                while pos < text.count {
                    if text[pos] == "'" {
                        if pos + 1 < text.count, text[pos + 1] == "'" { s.append("'"); pos += 2; continue }
                        closed = true; pos += 1; break
                    }
                    s.append(text[pos]); pos += 1
                }
                guard closed else { throw error("Unexpected symbol", at: start) }
                out.append((.string(s), start))
            case "!":
                if pos + 1 < text.count, text[pos + 1] == "=" { out.append((.neq, start)); pos += 2 } else { tok(.not) }
            case ">":
                if pos + 1 < text.count, text[pos + 1] == "=" { out.append((.gte, start)); pos += 2 } else { tok(.gt) }
            case "<":
                if pos + 1 < text.count, text[pos + 1] == "=" { out.append((.lte, start)); pos += 2 } else { tok(.lt) }
            case "=":
                guard pos + 1 < text.count, text[pos + 1] == "=" else { throw error("Unexpected symbol", at: start) }
                out.append((.eq, start)); pos += 2
            case "&":
                guard pos + 1 < text.count, text[pos + 1] == "&" else { throw error("Unexpected symbol", at: start) }
                out.append((.and, start)); pos += 2
            case "|":
                guard pos + 1 < text.count, text[pos + 1] == "|" else { throw error("Unexpected symbol", at: start) }
                out.append((.or, start)); pos += 2
            case ".":
                let operandPosition: Bool
                switch prev {
                case nil, .comma, .lparen, .lbracket, .and, .or, .not, .eq, .neq, .lt, .lte, .gt, .gte: operandPosition = true
                default: operandPosition = false
                }
                if operandPosition { try readNumber(into: &out, start: start) } else { tok(.dot) }
            case "-", "+", "0"..."9":
                try readNumber(into: &out, start: start)
            default:
                guard c.isLetter || c == "_" else { throw error("Unexpected symbol", at: start) }
                var name = ""
                while pos < text.count, !Lexer.boundary.contains(text[pos]) {
                    let ch = text[pos]
                    guard ch.isLetter || ch.isNumber || ch == "_" || ch == "-" else { throw error("Unexpected symbol", at: start) }
                    name.append(ch); pos += 1
                }
                if prev == .dot {
                    out.append((.ident(name), start))
                } else {
                    switch name {
                    case "null": out.append((.null, start))
                    case "true": out.append((.true, start))
                    case "false": out.append((.false, start))
                    case "NaN": out.append((.number(.nan), start))
                    case "Infinity": out.append((.number(.infinity), start))
                    default: out.append((.ident(name), start))
                    }
                }
            }
        }
    }

    private mutating func readNumber(into out: inout [(Token, Int)], start: Int) throws {
        var s = ""
        while pos < text.count, !Lexer.boundary.contains(text[pos]) || text[pos] == "." {
            s.append(text[pos]); pos += 1
        }
        let n = ExprValue.parseNumber(s)
        if s == "-Infinity" { out.append((.number(-.infinity), start)); return }
        guard !n.isNaN else { throw error("Unexpected symbol", at: start) }
        out.append((.number(n), start))
    }

    func error(_ msg: String, at: Int) -> ExpressionError {
        ExpressionError("\(msg): '\(String(text[at..<min(text.count, at + 1)]))'. Located at position \(at + 1)", expression: source)
    }
}

/// Recursive-descent parser for the expression grammar.
public struct ExpressionParser {
    public static let maxLength = 21000
    public static let maxDepth = 50

    private var tokens: [(Token, Int)] = []
    private var i = 0
    private let source: String
    private let namedValues: Set<String>?
    private let functions: [String: ClosedRange<Int>]

    public init(source: String, allowedNamedValues: Set<String>? = nil, functions: [String: ClosedRange<Int>] = ExpressionParser.defaultFunctions) {
        self.source = source
        self.namedValues = allowedNamedValues.map { Set($0.map { $0.lowercased() }) }
        var f: [String: ClosedRange<Int>] = [:]
        for (k, v) in functions { f[k.lowercased()] = v }
        self.functions = f
    }

    public static let defaultFunctions: [String: ClosedRange<Int>] = [
        "contains": 2...2, "startswith": 2...2, "endswith": 2...2, "format": 1...255,
        "join": 1...2, "tojson": 1...1, "fromjson": 1...1, "case": 3...255,
        "success": 0...255, "failure": 0...255, "cancelled": 0...0, "always": 0...0,
        "hashfiles": 1...255,
    ]

    public static func parse(_ source: String, allowedNamedValues: Set<String>? = nil,
                             functions: [String: ClosedRange<Int>] = defaultFunctions) throws -> ExprNode? {
        var p = ExpressionParser(source: source, allowedNamedValues: allowedNamedValues, functions: functions)
        return try p.run()
    }

    private mutating func run() throws -> ExprNode? {
        guard source.count <= ExpressionParser.maxLength else {
            throw ExpressionError("Exceeded max expression length \(ExpressionParser.maxLength)", expression: source)
        }
        var lexer = Lexer(source)
        tokens = try lexer.tokenize()
        if case .end = tokens[0].0 { return nil }
        let node = try parseOr(depth: 1)
        guard case .end = peek else { throw unexpected() }
        return node
    }

    private var peek: Token { tokens[i].0 }
    private mutating func advance() -> Token { let t = tokens[i].0; i += 1; return t }

    private func unexpected() -> ExpressionError {
        let (t, pos) = tokens[i]
        if case .end = t { return ExpressionError("Unexpected end of expression", expression: source) }
        let raw = String(Array(source)[pos..<min(source.count, pos + 1)])
        return ExpressionError("Unexpected symbol: '\(raw)'. Located at position \(pos + 1)", expression: source)
    }

    private func checkDepth(_ d: Int) throws {
        if d > ExpressionParser.maxDepth { throw ExpressionError("Exceeded max expression depth \(ExpressionParser.maxDepth)", expression: source) }
    }

    private mutating func parseOr(depth: Int) throws -> ExprNode {
        try checkDepth(depth)
        var items = [try parseAnd(depth: depth + 1)]
        while peek == .or { _ = advance(); items.append(try parseAnd(depth: depth + 1)) }
        return items.count == 1 ? items[0] : .or(items)
    }

    private mutating func parseAnd(depth: Int) throws -> ExprNode {
        var items = [try parseEquality(depth: depth + 1)]
        while peek == .and { _ = advance(); items.append(try parseEquality(depth: depth + 1)) }
        return items.count == 1 ? items[0] : .and(items)
    }

    private mutating func parseEquality(depth: Int) throws -> ExprNode {
        var left = try parseComparison(depth: depth + 1)
        while peek == .eq || peek == .neq {
            let op = advance() == .eq ? "==" : "!="
            left = .binary(op, left, try parseComparison(depth: depth + 1))
        }
        return left
    }

    private mutating func parseComparison(depth: Int) throws -> ExprNode {
        var left = try parseUnary(depth: depth + 1)
        while true {
            let op: String
            switch peek {
            case .lt: op = "<"
            case .lte: op = "<="
            case .gt: op = ">"
            case .gte: op = ">="
            default: return left
            }
            _ = advance()
            left = .binary(op, left, try parseUnary(depth: depth + 1))
        }
    }

    private mutating func parseUnary(depth: Int) throws -> ExprNode {
        try checkDepth(depth)
        if peek == .not { _ = advance(); return .not(try parseUnary(depth: depth + 1)) }
        return try parsePostfix(depth: depth + 1)
    }

    private mutating func parsePostfix(depth: Int) throws -> ExprNode {
        var node = try parsePrimary(depth: depth + 1)
        // Literals cannot be indexed directly ('abc'[0] is illegal) but grouped ones can.
        if case .literal = node, !lastWasGroup { return node }
        while true {
            if peek == .dot {
                _ = advance()
                switch peek {
                case .star: _ = advance(); node = .wildcard(node)
                case .ident(let name): _ = advance(); node = .index(node, .literal(.string(name)))
                default: throw unexpected()
                }
            } else if peek == .lbracket {
                _ = advance()
                if peek == .star {
                    _ = advance()
                    node = .wildcard(node)
                } else {
                    let idx = try parseOr(depth: depth + 1)
                    node = .index(node, idx)
                }
                guard peek == .rbracket else { throw unexpected() }
                _ = advance()
            } else {
                return node
            }
        }
    }

    private var lastWasGroup = false

    private mutating func parsePrimary(depth: Int) throws -> ExprNode {
        try checkDepth(depth)
        lastWasGroup = false
        switch advance() {
        case .number(let n): return .literal(.number(n))
        case .string(let s): return .literal(.string(s))
        case .null: return .literal(.null)
        case .true: return .literal(.bool(true))
        case .false: return .literal(.bool(false))
        case .lparen:
            let inner = try parseOr(depth: depth + 1)
            guard peek == .rparen else { throw unexpected() }
            _ = advance()
            lastWasGroup = true
            return inner
        case .ident(let name):
            if peek == .lparen {
                _ = advance()
                var args: [ExprNode] = []
                if peek != .rparen {
                    args.append(try parseOr(depth: depth + 1))
                    while peek == .comma { _ = advance(); args.append(try parseOr(depth: depth + 1)) }
                }
                guard peek == .rparen else { throw unexpected() }
                _ = advance()
                guard let range = functions[name.lowercased()] else {
                    throw ExpressionError("Unrecognized function: '\(name)'", expression: source)
                }
                if args.count < range.lowerBound { throw ExpressionError("Too few parameters supplied: '\(name)'", expression: source) }
                if args.count > range.upperBound { throw ExpressionError("Too many parameters supplied: '\(name)'", expression: source) }
                if name.lowercased() == "case", args.count % 2 == 0 {
                    throw ExpressionError("Even number of parameters supplied, requires an odd number of parameters: '\(name)'", expression: source)
                }
                return .function(name, args)
            }
            if let nv = namedValues, !nv.contains(name.lowercased()) {
                throw ExpressionError("Unrecognized named-value: '\(name)'", expression: source)
            }
            return .namedValue(name)
        default:
            i -= 1
            throw unexpected()
        }
    }
}

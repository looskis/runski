import XCTest
@testable import RunskiCore

final class ExpressionTests: XCTestCase {
    func ctx() -> ExpressionContext {
        var c = ExpressionContext(values: [
            "github": .obj([("ref", .string("refs/heads/main")), ("event_name", .string("push")),
                            ("event", .obj([("number", .number(42)), ("Labels", .arr([.string("bug"), .string("p1")]))]))]),
            "steps": .obj([("a", .obj([("outcome", .string("success")), ("outputs", .obj([("x", .string("1"))]))])),
                           ("b", .obj([("outcome", .string("failure")), ("outputs", .obj([]))]))]),
            "matrix": .obj([("os", .string("macos")), ("node", .number(20))]),
            "env": .obj([("FOO", .string("bar"))], caseSensitive: true),
            "job": .obj([("status", .string("success"))]),
        ])
        c.setFunction("success") { _ in .bool(true) }
        c.setFunction("failure") { _ in .bool(false) }
        c.setFunction("cancelled") { _ in .bool(false) }
        c.setFunction("always") { _ in .bool(true) }
        return c
    }

    func eval(_ s: String) throws -> ExprValue { try Expression.evaluate(s, context: ctx()) }
    func str(_ s: String) throws -> String { try eval(s).asString }

    func testLiteralsAndOperators() throws {
        XCTAssertEqual(try str("1 == 1"), "true")
        XCTAssertEqual(try str("null == 0"), "true")
        XCTAssertEqual(try str("null == ''"), "true")
        XCTAssertEqual(try str("'1' == true"), "true")
        XCTAssertEqual(try str("'true' == true"), "false")
        XCTAssertEqual(try str("'abc' == 'ABC'"), "true")
        XCTAssertEqual(try str("' 1 ' == 1"), "true")
        XCTAssertEqual(try str("'0x10' == 16"), "true")
        XCTAssertEqual(try str("NaN == NaN"), "false")
        XCTAssertEqual(try str("1 < 2 < 3"), "true")
        XCTAssertEqual(try str("'a' < '_'"), "true")
        XCTAssertEqual(try str("!true"), "false")
        XCTAssertEqual(try str("!github.missing"), "true")
        XCTAssertEqual(try str("'' || 'x'"), "x")
        XCTAssertEqual(try str("'a' && 'b'"), "b")
        XCTAssertEqual(try str("0 && 'b'"), "0")
        XCTAssertEqual(try str("(1 == 1) && (2 > 1)"), "true")
    }

    func testDereference() throws {
        XCTAssertEqual(try str("github.ref"), "refs/heads/main")
        XCTAssertEqual(try str("GITHUB.REF"), "refs/heads/main")
        XCTAssertEqual(try str("github['ref']"), "refs/heads/main")
        XCTAssertEqual(try str("github.event.number"), "42")
        XCTAssertEqual(try str("github.event.labels[1]"), "p1")
        XCTAssertEqual(try str("github.event.labels['1']"), "p1")
        XCTAssertEqual(try str("github.event.labels[1.9]"), "p1")
        XCTAssertEqual(try str("github.event.labels[-1]"), "")
        XCTAssertEqual(try str("github.nope.deeper"), "")
        XCTAssertEqual(try str("env.FOO"), "bar")
        XCTAssertEqual(try str("env.foo"), "")
        XCTAssertEqual(try str("steps.a.outputs.x"), "1")
        XCTAssertEqual(try str("join(steps.*.outcome)"), "success,failure")
        XCTAssertEqual(try str("contains(steps.*.outcome, 'failure')"), "true")
        XCTAssertEqual(try str("join(steps.*.outputs.x, '|')"), "1")
    }

    func testFunctions() throws {
        XCTAssertEqual(try str("contains('Hello', 'ELL')"), "true")
        XCTAssertEqual(try str("contains('Hello', '')"), "true")
        XCTAssertEqual(try str("contains(github.event.labels, 'BUG')"), "true")
        XCTAssertEqual(try str("contains(fromJSON('[1,2]'), '1')"), "true")
        XCTAssertEqual(try str("startsWith('Hello', 'he')"), "true")
        XCTAssertEqual(try str("endsWith('Hello', 'LO')"), "true")
        XCTAssertEqual(try str("startsWith(null, '')"), "true")
        XCTAssertEqual(try str("format('{0} {1} {{x}}', 'a', 1.5)"), "a 1.5 {x}")
        XCTAssertEqual(try str("format('{0}', github.event.labels)"), "Array")
        XCTAssertThrowsError(try eval("format('{0} {1}', 'a')"))
        XCTAssertThrowsError(try eval("format('{x}', 'a')"))
        XCTAssertEqual(try str("format('x', 'unused')"), "x")
        XCTAssertEqual(try str("join(github.event.labels, ', ')"), "bug, p1")
        XCTAssertEqual(try str("join('solo')"), "solo")
        XCTAssertEqual(try str("join(fromJSON('[]'))"), "")
        XCTAssertEqual(try str("toJSON(matrix)"), "{\n  \"os\": \"macos\",\n  \"node\": 20\n}")
        XCTAssertEqual(try str("toJSON(fromJSON('[]'))"), "[]")
        XCTAssertEqual(try str("fromJSON('{\"a\": {\"b\": [1, true]}}').a.b[1]"), "true")
        XCTAssertEqual(try str("fromJSON('{}') == fromJSON('{}')"), "false")
        XCTAssertEqual(try str("matrix == matrix"), "true")
        XCTAssertEqual(try str("case(false, 'a', true, 'b', 'c')"), "b")
        XCTAssertEqual(try str("case(false, 'a', 'c')"), "c")
        XCTAssertThrowsError(try eval("case('x', 'a', 'c')"))
        XCTAssertEqual(try str("success() && github.event_name == 'push'"), "true")
        XCTAssertEqual(try str("failure() || cancelled()"), "false")
        XCTAssertEqual(try str("always()"), "true")
    }

    func testNumberFormatting() {
        XCTAssertEqual(ExprValue.formatNumber(1.0), "1")
        XCTAssertEqual(ExprValue.formatNumber(1.5), "1.5")
        XCTAssertEqual(ExprValue.formatNumber(0.1 + 0.2), "0.3")
        XCTAssertEqual(ExprValue.formatNumber(1.0 / 3.0), "0.333333333333333")
        XCTAssertEqual(ExprValue.formatNumber(1e14), "100000000000000")
        XCTAssertEqual(ExprValue.formatNumber(1e15), "1E+15")
        XCTAssertEqual(ExprValue.formatNumber(0.0001), "0.0001")
        XCTAssertEqual(ExprValue.formatNumber(0.00001), "1E-05")
        XCTAssertEqual(ExprValue.formatNumber(1.5e-7), "1.5E-07")
        XCTAssertEqual(ExprValue.formatNumber(.nan), "NaN")
        XCTAssertEqual(ExprValue.formatNumber(.infinity), "Infinity")
        XCTAssertEqual(ExprValue.formatNumber(-0.0), "0")
        XCTAssertEqual(ExprValue.parseNumber("0xFFFFFFFF"), -1)
        XCTAssertTrue(ExprValue.parseNumber("0x100000000").isNaN)
        XCTAssertEqual(ExprValue.parseNumber("0o17"), 15)
        XCTAssertEqual(ExprValue.parseNumber(""), 0)
        XCTAssertEqual(ExprValue.parseNumber(" .5 "), 0.5)
        XCTAssertEqual(ExprValue.parseNumber("1."), 1)
        XCTAssertTrue(ExprValue.parseNumber("1_000").isNaN)
    }

    func testParseErrors() {
        XCTAssertThrowsError(try eval("github.ref ="))
        XCTAssertThrowsError(try eval("unknownctx.x"))
        XCTAssertThrowsError(try eval("nofunc(1)"))
        XCTAssertThrowsError(try eval("contains('a')"))
        XCTAssertThrowsError(try eval("'abc'[0]"))
        XCTAssertThrowsError(try eval("\"x\""))
        XCTAssertNoThrow(try eval("('abc')[0]"))
        XCTAssertThrowsError(try eval("1 -1"))
    }

    func testConditionNormalization() throws {
        XCTAssertEqual(try Expression.normalizeCondition(nil), "success()")
        XCTAssertEqual(try Expression.normalizeCondition("github.ref == 'x'"), "success() && (github.ref == 'x')")
        XCTAssertEqual(try Expression.normalizeCondition("${{ github.ref == 'x' }}"), "success() && (github.ref == 'x')")
        XCTAssertEqual(try Expression.normalizeCondition("failure() || true"), "failure() || true")
        XCTAssertEqual(try Expression.normalizeCondition("!cancelled()"), "!cancelled()")
        XCTAssertTrue(try Expression.evaluateCondition("success() && (github.event_name == 'push')", context: ctx()))
        XCTAssertFalse(try Expression.evaluateCondition("github.event_name == 'pull_request'", context: ctx()))
    }

    func testTemplateScalar() throws {
        XCTAssertEqual(try TemplateScalar.parse("plain").token, .string("plain"))
        XCTAssertEqual(try TemplateScalar.parse("${{ github.ref }}").token, .expression("github.ref"))
        XCTAssertEqual(try TemplateScalar.parse("${{ 'lit' }}").token, .string("lit"))
        XCTAssertEqual(try TemplateScalar.parse("a ${{ github.ref }} b {x} it's").token,
                       .expression("format('a {0} b {{x}} it''s', github.ref)"))
        XCTAssertEqual(try TemplateScalar.parse("${{ '}}' }}x").token, .expression("format('{0}x', '}}')"))
        XCTAssertThrowsError(try TemplateScalar.parse("${{ github.ref"))
        let mixed = try TemplateScalar.parse("ref=${{ github.ref }} n=${{ github.event.number }}").token
        XCTAssertEqual(try TemplateEvaluator.evaluateString(mixed, context: ctx()), "ref=refs/heads/main n=42")
    }

    func testTemplateTokenDecoding() throws {
        let json = """
        {"type":2,"map":[{"Key":"script","Value":{"type":0,"file":1,"line":3,"col":5,"lit":"echo hi"}},
                         {"key":"shell","value":"bash"},
                         {"Key":{"type":0,"lit":"expr"},"Value":{"type":3,"expr":"github.ref"}},
                         {"Key":"n","Value":3},{"Key":"b","Value":true},{"Key":"seq","Value":{"type":1,"seq":["a",{"type":3,"expr":"matrix.os"}]}}]}
        """
        let tok = try ServiceJSON.decoder().decode(TemplateToken.self, from: Data(json.utf8))
        XCTAssertEqual(tok["script"], .string("echo hi"))
        XCTAssertEqual(tok["SHELL"], .string("bash"))
        XCTAssertEqual(tok["expr"], .expression("github.ref"))
        XCTAssertEqual(tok["n"], .number(3))
        XCTAssertEqual(tok["b"], .boolean(true))
        let v = try TemplateEvaluator.evaluate(tok, context: ctx())
        XCTAssertEqual(v.objectValue?["expr"]?.asString, "refs/heads/main")
        XCTAssertEqual(v.objectValue?["seq"]?.arrayValue?.items.map(\.asString), ["a", "macos"])
        XCTAssertThrowsError(try TemplateEvaluator.evaluateStringMap(tok, context: ctx()))
        if case .mapping(let pairs) = tok {
            let map = try TemplateEvaluator.evaluateStringMap(.mapping(Array(pairs.dropLast())), context: ctx())
            XCTAssertEqual(map.map(\.0), ["script", "shell", "expr", "n", "b"])
            XCTAssertEqual(map.map(\.1), ["echo hi", "bash", "refs/heads/main", "3", "true"])
        } else { XCTFail() }
    }

    func testContextDataDecoding() throws {
        let json = """
        {"github":{"t":2,"d":[{"k":"ref","v":"refs/heads/x"},{"k":"event","v":{"t":2,"d":[{"k":"n","v":{"t":4,"n":7}}]}},
                                {"k":"arr","v":{"t":1,"a":["a",true,null]}}]},
         "matrix":null,"vars":{"t":5,"d":[{"k":"X","v":"1"}]}}
        """
        let ctxData = try ServiceJSON.decoder().decode([String: ContextData].self, from: Data(json.utf8))
        XCTAssertEqual(ctxData["github"]?["ref"]?.stringValue, "refs/heads/x")
        XCTAssertEqual(ctxData["github"]?["event"]?["n"], .number(7))
        XCTAssertEqual(ctxData["matrix"], .null)
        XCTAssertEqual(ctxData["vars"]?["X"]?.stringValue, "1")
        XCTAssertNil(ctxData["vars"]?["x"])
        let v = ExprValue.from(ctxData["github"]!)
        XCTAssertEqual(v.objectValue?["arr"]?.arrayValue?.items.count, 3)
    }
}

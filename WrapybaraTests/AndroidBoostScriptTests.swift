import JavaScriptCore
import XCTest
@testable import Wrapybara

final class AndroidBoostScriptTests: XCTestCase {
    private func context() throws -> JSContext {
        let context = try XCTUnwrap(JSContext())
        context.exceptionHandler = { _, error in
            XCTFail("JavaScript failed: \(error?.toString() ?? "unknown")")
        }
        // A minimal DOM exercises the shipped script without WebKit or a network.
        context.evaluateScript(#"""
        var window = this;
        var location = {href: 'https://example.com/docs', hostname: 'example.com', protocol: 'https:'};
        var listeners = {};
        var elements = {};
        var container = {appendChild: function (e) { elements[e.id] = e; }};
        var document = {
          head: container, documentElement: container,
          getElementById: function (id) { return elements[id]; },
          createElement: function () { return {textContent: ''}; }
        };
        var history = {pushState: function (_, __, url) { location.href = url; },
                       replaceState: function (_, __, url) { location.href = url; }};
        window.addEventListener = function (name, callback) { listeners[name] = callback; };
        var console = {warn: function () {}};
        function css() { return elements.__wrapybara_android_style.textContent; }
        """#)
        return context
    }

    private func evaluate(_ sources: [String], in context: JSContext) {
        for source in sources { context.evaluateScript(source) }
    }

    func testOnlyTrustedPostLoadScriptsRunAndDisabledBoostsAreAbsent() throws {
        let boosts = [
            Boost(name: "trusted", javaScript: "window.trusted = (window.trusted || 0) + 1"),
            Boost(name: "untrusted", css: "body { color: red }", javaScript: "window.untrusted = true",
                  isJavaScriptTrusted: false),
            Boost(name: "early", javaScript: "window.early = true", javaScriptInjectionTime: .documentStart),
            Boost(name: "disabled", isEnabled: false, css: "disabled", javaScript: "window.disabled = true"),
        ]
        let script = try AndroidBoostScript.make(boosts: boosts)
        XCTAssertFalse(script.joined().contains("window.untrusted"))
        XCTAssertFalse(script.joined().contains("window.early"))
        let js = try context()
        evaluate(script, in: js)
        evaluate(script, in: js)
        XCTAssertEqual(js.evaluateScript("trusted")?.toInt32(), 1)
        XCTAssertTrue(js.evaluateScript("typeof untrusted === 'undefined' && typeof early === 'undefined' && typeof disabled === 'undefined'")?.toBool() == true)
        XCTAssertTrue(js.evaluateScript("css()")?.toString().contains("color: red") == true)
    }

    func testCSSRescopesAcrossSPANavigationWithoutRepeatingScripts() throws {
        let boost = Boost(match: BoostMatch(kind: .urlPrefix, pattern: "https://example.com/docs"),
                          css: "body { color: red }", javaScript: "window.runs = (window.runs || 0) + 1")
        let js = try context()
        evaluate(try AndroidBoostScript.make(boosts: [boost]), in: js)
        XCTAssertTrue(js.evaluateScript("css()")?.toString().contains("color: red") == true)
        js.evaluateScript("history.pushState(null, '', 'https://example.com/other')")
        XCTAssertEqual(js.evaluateScript("css()")?.toString(), "")
        js.evaluateScript("history.replaceState(null, '', 'https://example.com/docs/again')")
        XCTAssertTrue(js.evaluateScript("css()")?.toString().contains("color: red") == true)
        XCTAssertEqual(js.evaluateScript("runs")?.toInt32(), 1)
    }

    func testTrustedScriptsDoNotRequirePageEval() throws {
        let js = try context()
        js.evaluateScript("window.eval = function () { throw new Error('String evaluation is blocked'); }")
        evaluate(try AndroidBoostScript.make(boosts: [
            Boost(javaScript: "window.executedWithoutEval = true")
        ]), in: js)
        XCTAssertTrue(js.evaluateScript("window.executedWithoutEval === true")?.toBool() == true)
    }

    func testMalformedScriptCannotEscapeItsScope() throws {
        let closeout = "}); window.escapedScope = true; window.__wrapybaraAndroid.register('unused', function () {"
        let boost = Boost(name: "Invalid script", match: .domain("other.example"), javaScript: closeout)
        XCTAssertThrowsError(try AndroidBoostScript.make(boosts: [boost])) { error in
            XCTAssertTrue(error.localizedDescription.contains("Invalid script"))
        }
    }

    func testValidationDoesNotExecuteScripts() throws {
        XCTAssertNoThrow(try AndroidBoostScript.make(boosts: [
            Boost(javaScript: "throw new Error('This must not run during export')")
        ]))
    }

    func testDomainBoundaryGlobsRegexAndInvalidPatterns() throws {
        let cases: [(BoostMatch, Bool)] = [
            (.domain("HTTPS://EXAMPLE.COM/path"), true),
            (.domain("ample.com"), false),
            (BoostMatch(kind: .glob, pattern: "https://example.com/d?cs"), true),
            (BoostMatch(kind: .glob, pattern: "https://exampleXcom/*"), false),
            (BoostMatch(kind: .regex, pattern: "/DOCS$"), true),
            (BoostMatch(kind: .regex, pattern: "/DOCS$", isCaseSensitive: true), false),
            (BoostMatch(kind: .regex, pattern: "["), false),
            (BoostMatch(kind: .regex, pattern: ""), false),
        ]
        for (match, expected) in cases {
            let js = try context()
            evaluate(try AndroidBoostScript.make(boosts: [Boost(match: match, css: "matched")]), in: js)
            XCTAssertEqual(js.evaluateScript("css().includes('matched')")?.toBool(), expected,
                           match.pattern)
        }
    }

    func testStylesheetCannotBecomeExecutableCode() throws {
        let css = "body::after {content: '\"}; window.pwned=true; //'}\n</script>\u{2028}/* end */"
        let js = try context()
        evaluate(try AndroidBoostScript.make(boosts: [Boost(css: css)]), in: js)
        XCTAssertTrue(js.evaluateScript("typeof pwned === 'undefined'")?.toBool() == true)
        XCTAssertTrue(js.evaluateScript("css()")?.toString().contains(css) == true)
    }
}

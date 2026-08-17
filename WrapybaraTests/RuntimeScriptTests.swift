import XCTest
@testable import Wrapybara

/// The injected JavaScript and the session store.
///
/// The scripts can't be executed here (that needs a real web view), so what's tested is
/// the part that *is* deterministic: that the generated source is well-formed, that a
/// stylesheet can't break out of the string literal it's embedded in, and that each
/// script is present when it should be.
final class RuntimeScriptTests: XCTestCase {

    // MARK: String literal embedding

    func testStylesheetIsEmbeddedAsAValidJSONStringLiteral() throws {
        // The CSS goes into the script as a literal. If quoting leaked, the script would
        // either fail to parse or — worse — execute part of the stylesheet as code.
        let nasty = #"body::after { content: "\" }; alert(1); //" }"# + "\n</script>\u{2028}"
        let literal = BoostScripts.jsStringLiteral(nasty)

        XCTAssertTrue(literal.hasPrefix("\""))
        XCTAssertTrue(literal.hasSuffix("\""))
        // Decoding the literal as JSON has to give back exactly what went in.
        let decoded = try JSONSerialization.jsonObject(
            with: Data(literal.utf8), options: [.fragmentsAllowed]) as? String
        XCTAssertEqual(decoded, nasty)
    }

    func testLiteralEscapesLineSeparators() {
        // U+2028 and U+2029 terminate a line in JavaScript but not in JSON, so they have to
        // come out escaped or the script breaks at that character.
        let literal = BoostScripts.jsStringLiteral("a\u{2028}b\u{2029}c")
        XCTAssertFalse(literal.contains("\u{2028}"))
        XCTAssertFalse(literal.contains("\u{2029}"))
    }

    func testLiteralHandlesEmptyAndUnicode() {
        XCTAssertEqual(BoostScripts.jsStringLiteral(""), "\"\"")
        XCTAssertTrue(BoostScripts.jsStringLiteral("café ☕").contains("caf"))
    }

    // MARK: Script shape

    func testStylesheetScriptCarriesTheCSSAndTheElementID() {
        let script = BoostScripts.applyStylesheet("body { color: red }")
        XCTAssertTrue(script.contains("body { color: red }"))
        XCTAssertTrue(script.contains(BoostScripts.styleElementID))
        // Everything is namespaced so nothing can collide with the page's own globals.
        XCTAssertTrue(script.contains("window.__wrapybara"))
    }

    func testScriptsAreWrappedInAnIIFE() {
        for script in [BoostScripts.elementPicker, BoostScripts.selectorBuilder,
                       BoostScripts.notificationShim, BoostScripts.navigationReporter,
                       BoostScripts.applyStylesheet("")] {
            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(trimmed.hasPrefix("(function"), "not an IIFE: \(trimmed.prefix(40))")
            XCTAssertTrue(trimmed.hasSuffix("})();"))
        }
    }

    func testBracketsBalanceInEveryScript() {
        // A crude but effective guard against an interpolation accidentally eating a brace.
        for (name, script) in [("picker", BoostScripts.elementPicker),
                               ("selector", BoostScripts.selectorBuilder),
                               ("notification", BoostScripts.notificationShim),
                               ("navigation", BoostScripts.navigationReporter),
                               ("stylesheet", BoostScripts.applyStylesheet("body{}"))] {
            for (open, close) in [(Character("{"), Character("}")),
                                  (Character("("), Character(")")),
                                  (Character("["), Character("]"))] {
                let opens = script.filter { $0 == open }.count
                let closes = script.filter { $0 == close }.count
                XCTAssertEqual(opens, closes, "\(name): unbalanced \(open)\(close)")
            }
        }
    }

    func testHandlerNamesAreReferencedByTheScriptsThatPostToThem() {
        XCTAssertTrue(BoostScripts.elementPicker.contains(BoostScripts.Handler.picker))
        XCTAssertTrue(BoostScripts.notificationShim.contains(BoostScripts.Handler.notification))
        XCTAssertTrue(BoostScripts.navigationReporter.contains(BoostScripts.Handler.navigated))
    }

    func testPickerNeverWidensPastBody() {
        // Selecting <body> would hide the whole page.
        XCTAssertTrue(BoostScripts.elementPicker.contains("document.body"))
    }

    func testSelectorBuilderRejectsGeneratedClassNames() {
        // A selector built from a bundler-generated hash stops matching on the next deploy.
        XCTAssertTrue(BoostScripts.selectorBuilder.contains("looksGenerated"))
    }

    // MARK: Injector

    private func configuration(_ boosts: [Boost],
                               forwardsNotifications: Bool = false) -> WrapConfiguration {
        var wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        wrap.behavior.forwardsWebNotifications = forwardsNotifications
        return WrapConfiguration.resolved(wrap, boosts: boosts, generatedBy: "test")
    }

    func testInjectorAlwaysInstallsTheStylesheetEvenWhenEmpty() {
        // An empty stylesheet is how a boost being switched *off* takes effect on a page
        // that is already open.
        let injector = BoostInjector(configuration: configuration([]))
        let scripts = injector.userScripts(for: URL(string: "https://a.test/")!)
        XCTAssertTrue(scripts.contains { $0.source.contains(BoostScripts.styleElementID) })
    }

    func testInjectorOmitsTheNotificationShimUnlessAsked() {
        let off = BoostInjector(configuration: configuration([]))
        XCTAssertFalse(off.userScripts(for: URL(string: "https://a.test/")!)
            .contains { $0.source.contains("ShimNotification") })

        let on = BoostInjector(configuration: configuration([], forwardsNotifications: true))
        XCTAssertTrue(on.userScripts(for: URL(string: "https://a.test/")!)
            .contains { $0.source.contains("ShimNotification") })
    }

    func testInjectorRunsAllScriptsInTheMainFrameOnly() {
        // Running a boost's script in every ad iframe would be wasteful, and for a boost
        // with JavaScript it would quietly widen what the user thought they enabled.
        var boost = Boost(name: "S")
        boost.javaScript = "1"
        boost.isJavaScriptTrusted = true
        let injector = BoostInjector(configuration: configuration([boost]))
        for script in injector.userScripts(for: URL(string: "https://a.test/")!) {
            XCTAssertTrue(script.isForMainFrameOnly)
        }
    }

    func testInjectorSkipsAnUntrustedScript() {
        var boost = Boost(name: "Imported")
        boost.javaScript = "alert(1)"
        boost.isJavaScriptTrusted = false
        let injector = BoostInjector(configuration: configuration([boost]))
        XCTAssertFalse(injector.userScripts(for: URL(string: "https://a.test/")!)
            .contains { $0.source.contains("alert(1)") })
    }

    func testInjectorHonoursTheChosenInjectionTime() {
        var early = Boost(name: "Early")
        early.javaScript = "earlyMarker"
        early.isJavaScriptTrusted = true
        early.javaScriptInjectionTime = .documentStart
        let injector = BoostInjector(configuration: configuration([early]))
        let script = injector.userScripts(for: URL(string: "https://a.test/")!)
            .first { $0.source.contains("earlyMarker") }
        XCTAssertEqual(script?.injectionTime, .atDocumentStart)
    }

    func testBoostScriptIsWrappedSoOneFailureCannotStopTheOthers() {
        var boost = Boost(name: "Breaks")
        boost.javaScript = "throw new Error('x')"
        boost.isJavaScriptTrusted = true
        let injector = BoostInjector(configuration: configuration([boost]))
        let wrapped = injector.wrapped(boost)
        XCTAssertTrue(wrapped.contains("try {"))
        XCTAssertTrue(wrapped.contains("catch (error)"))
        // The name goes into the console message, because "a boost threw" is useless when
        // six are enabled.
        XCTAssertTrue(wrapped.contains("\"Breaks\""))
    }

    func testInjectorSummary() {
        let url = URL(string: "https://a.test/")!
        XCTAssertEqual(BoostInjector(configuration: configuration([])).summary(for: url),
                       "No boosts on this page")

        var boost = Boost(name: "Dark")
        boost.theme.backgroundColor = "#000000"
        XCTAssertEqual(BoostInjector(configuration: configuration([boost])).summary(for: url),
                       "1 boost: Dark")
    }

    // MARK: Notification payloads

    func testPayloadValidation() {
        XCTAssertNil(NotificationBridge.Payload(nil))
        XCTAssertNil(NotificationBridge.Payload("a string"))
        XCTAssertNil(NotificationBridge.Payload(["id": 1]))            // no text at all
        XCTAssertNil(NotificationBridge.Payload(["title": "  "]))

        let payload = NotificationBridge.Payload(["id": 3, "title": "New message",
                                                 "body": "hi", "tag": "chat", "silent": true])
        XCTAssertEqual(payload?.id, 3)
        XCTAssertEqual(payload?.title, "New message")
        XCTAssertEqual(payload?.isSilent, true)
    }

    func testPayloadCollapsesNewlinesAndCapsLength() {
        // This comes from page JavaScript; a runaway script must not be able to hand over a
        // megabyte of "title".
        let long = String(repeating: "x", count: 5_000)
        let payload = NotificationBridge.Payload(["title": "a\nb", "body": long])
        XCTAssertEqual(payload?.title, "a b")
        XCTAssertEqual(payload?.body.count, NotificationBridge.Payload.maximumTextLength)
    }

    // MARK: Session store

    func testSessionRoundTrips() {
        let id = UUID()
        let defaults = UserDefaults(suiteName: "WrapybaraTests.\(id.uuidString)")!
        defer { defaults.removeSuite(named: "WrapybaraTests.\(id.uuidString)") }

        SessionStore.save([Data("a".utf8), Data("b".utf8)], wrapID: id, defaults: defaults)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults),
                       [Data("a".utf8), Data("b".utf8)])

        SessionStore.clear(wrapID: id, defaults: defaults)
        XCTAssertTrue(SessionStore.load(wrapID: id, defaults: defaults).isEmpty)
    }

    func testSessionDropsEmptyAndOversizedStates() {
        let id = UUID()
        let suite = "WrapybaraTests.\(id.uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removeSuite(named: suite) }

        let huge = Data(count: SessionStore.maximumStateBytes + 1)
        SessionStore.save([Data(), huge, Data("ok".utf8)], wrapID: id, defaults: defaults)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults), [Data("ok".utf8)])
    }

    func testSessionCapsWindowCount() {
        let id = UUID()
        let suite = "WrapybaraTests.\(id.uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removeSuite(named: suite) }

        // Restoring forty windows would spawn forty web content processes at launch.
        let many = (0..<40).map { Data("\($0)".utf8) }
        SessionStore.save(many, wrapID: id, defaults: defaults)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults).count,
                       SessionStore.maximumWindows)
    }
}

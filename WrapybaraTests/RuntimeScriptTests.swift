import AppKit
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

    /// A fresh `UserDefaults` suite per test, so nothing leaks between them.
    private func makeDefaults() -> (defaults: UserDefaults, suite: String) {
        let suite = "WrapybaraTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (defaults, suite)
    }

    private func geometry(x: Double = 10, y: Double = 20,
                          screen: NSRect = NSRect(x: 0, y: 0, width: 1920, height: 1080))
        -> WindowGeometry {
        WindowGeometry(frame: NSRect(x: x, y: y, width: 800, height: 600),
                       screenFrame: screen, isFullScreen: false)
    }

    func testSessionRoundTrips() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removeSuite(named: suite) }
        let id = UUID()

        let states: [SessionStore.WindowState] = [
            .init(geometry: geometry(), interactionState: Data("a".utf8)),
            .init(geometry: nil, interactionState: Data("b".utf8)),
        ]
        SessionStore.save(states, wrapID: id, defaults: defaults)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults), states)

        SessionStore.clear(wrapID: id, defaults: defaults)
        XCTAssertTrue(SessionStore.load(wrapID: id, defaults: defaults).isEmpty)
    }

    func testSessionDropsEmptyAndOversizedStates() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removeSuite(named: suite) }
        let id = UUID()

        let huge = Data(count: SessionStore.maximumStateBytes + 1)
        SessionStore.save([.init(geometry: nil, interactionState: Data()),
                           .init(geometry: nil, interactionState: huge),
                           .init(geometry: nil, interactionState: Data("ok".utf8))],
                          wrapID: id, defaults: defaults)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults),
                       [.init(geometry: nil, interactionState: Data("ok".utf8))])
    }

    func testSessionCapsWindowCount() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removeSuite(named: suite) }
        let id = UUID()

        // Restoring forty windows would spawn forty web content processes at launch.
        let many = (0..<40).map {
            SessionStore.WindowState(geometry: nil, interactionState: Data("\($0)".utf8))
        }
        SessionStore.save(many, wrapID: id, defaults: defaults)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults).count,
                       SessionStore.maximumWindows)
    }

    func testSessionKeepsAWindowWithOnlyGeometryOrOnlyPages() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removeSuite(named: suite) }
        let id = UUID()

        // A geometry-only window is a session saved with page restore off; a
        // pages-only window is one saved by an older runtime. A window with neither
        // is nothing to reopen.
        let place = geometry()
        let pages = Data("pages".utf8)
        SessionStore.save([.init(geometry: place, interactionState: nil),
                           .init(geometry: nil, interactionState: pages),
                           .init(geometry: nil, interactionState: nil)],
                          wrapID: id, defaults: defaults)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults),
                       [.init(geometry: place, interactionState: nil),
                        .init(geometry: nil, interactionState: pages)])
    }

    func testSessionDropsGeometryWithoutAFrame() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removeSuite(named: suite) }
        let id = UUID()

        let zeroed = WindowGeometry(frame: .zero, screenFrame: .zero, isFullScreen: false)
        XCTAssertTrue(SessionStore.load(wrapID: id, defaults: defaults).isEmpty)
        SessionStore.save([.init(geometry: zeroed, interactionState: nil)],
                          wrapID: id, defaults: defaults)
        XCTAssertTrue(SessionStore.load(wrapID: id, defaults: defaults).isEmpty)
    }

    func testLegacySessionIsReadAndRetired() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removeSuite(named: suite) }
        let id = UUID()

        // What the previous runtime wrote: bare interaction blobs under the old key.
        let legacyKey = "SessionStore.\(id.uuidString).windows"
        let blob = Data("legacy".utf8)
        defaults.set([blob], forKey: legacyKey)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults),
                       [.init(geometry: nil, interactionState: blob)])

        // Saving the new format retires the old key, so the two can't drift apart —
        // an older runtime relaunching must not resurrect stale pages over the
        // newer session.
        SessionStore.save([.init(geometry: geometry(), interactionState: nil)],
                          wrapID: id, defaults: defaults)
        XCTAssertNil(defaults.data(forKey: legacyKey))
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults).count, 1)
    }

    func testSessionCapAppliesToLegacySessionsToo() {
        let (defaults, suite) = makeDefaults()
        defer { defaults.removeSuite(named: suite) }
        let id = UUID()

        let legacyKey = "SessionStore.\(id.uuidString).windows"
        let many = (0..<40).map { Data("\($0)".utf8) }
        defaults.set(many, forKey: legacyKey)
        XCTAssertEqual(SessionStore.load(wrapID: id, defaults: defaults).count,
                       SessionStore.maximumWindows)
    }
}

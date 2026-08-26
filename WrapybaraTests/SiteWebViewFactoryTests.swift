import XCTest
import WebKit
@testable import Wrapybara

/// The testable part of the web-view factory: that a wrap's web view opts out of
/// everything macOS does to a page whose window it thinks nobody is looking at —
/// hidden-page timer throttling, process suppression, and (the one that actually
/// stops a streaming chat) treating a covered window as a hidden page. All of it
/// rides undocumented WebKit keys, so these tests pin both that they're set and
/// that the keys are still ones WebKit knows.
final class SiteWebViewFactoryTests: XCTestCase {

    /// A message-handler stub, so `makeWebView` has something to register.
    private final class StubHandler: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {}
    }

    private func fixtureWrap() -> Wrap {
        Wrap(name: "Test", homeURL: URL(string: "https://a.test")!,
             bundleIdentifier: "com.example.test")
    }

    /// Asserts `key` is present and false on `preferences`. `value(forKey:)` on a
    /// key WebKit no longer knows raises an uncatchable `NSUndefinedKeyException`,
    /// so the same setter probe production uses comes first — and it has to halt
    /// execution, because `XCTAssertTrue` only records a failure and would let the
    /// read through.
    private func assertThrottlingDisabled(_ key: String, on preferences: WKPreferences) {
        guard SiteWebViewFactory.respondsToSetter(for: key, on: preferences) else {
            XCTFail("\(key) is no longer a known WKPreferences key")
            return
        }
        XCTAssertFalse(preferences.value(forKey: key) as? Bool ?? true,
                       "\(key) should be disabled")
    }

    /// Every key the factory opts out of must actually be set false. Iterating the
    /// production list rather than hardcoding keys means a fourth key added to
    /// `hiddenPageThrottlingPreferenceKeys` is asserted automatically — and the
    /// guard above fails loudly if a key WebKit has retired was never set.
    func testAllConfiguredThrottlingKeysAreDisabled() {
        let configuration = WKWebViewConfiguration()
        SiteWebViewFactory.preventHiddenPageThrottling(configuration)
        for key in SiteWebViewFactory.hiddenPageThrottlingPreferenceKeys {
            assertThrottlingDisabled(key, on: configuration.preferences)
        }
    }

    /// The call site matters as much as the helper: a refactor or bad merge that
    /// drops `preventHiddenPageThrottling` from `makeWebView` would silently ship
    /// throttling back, and the helper test above would stay green. Build a real
    /// web view the way a wrap does and read the preferences back off it.
    func testMakeWebViewOptsOutOfHiddenPageThrottling() {
        let webView = SiteWebViewFactory.makeWebView(for: fixtureWrap(), messageHandler: StubHandler())
        for key in SiteWebViewFactory.hiddenPageThrottlingPreferenceKeys {
            assertThrottlingDisabled(key, on: webView.configuration.preferences)
        }
    }

    /// The occlusion opt-out is the one that keeps a *covered* window's page in the
    /// visible state, and so keeps `requestAnimationFrame`, CSS animation and the
    /// page's own streaming code running rather than firing `visibilitychange` at
    /// it. Read off a real web view, because that's where the key lives — it is a
    /// `WKWebView` property, not a preference, so nothing in the configuration
    /// would catch its loss.
    func testMakeWebViewKeepsThePageVisibleWhileTheWindowIsCovered() {
        let webView = SiteWebViewFactory.makeWebView(for: fixtureWrap(), messageHandler: StubHandler())
        let key = SiteWebViewFactory.windowOcclusionDetectionKey
        // Same order as `assertThrottlingDisabled`: probe before reading, because
        // `value(forKey:)` on a retired key raises uncatchably, and halt rather than
        // record — `XCTFail` alone would let the read through.
        guard SiteWebViewFactory.respondsToSetter(for: key, on: webView) else {
            XCTFail("\(key) is no longer a known WKWebView key")
            return
        }
        XCTAssertFalse(webView.value(forKey: key) as? Bool ?? true,
                       "a covered window must not put its page into the hidden state")
    }

    // MARK: Web Inspector

    /// Reads the context-menu half of the inspector permission back off `webView`.
    /// Same order as `assertThrottlingDisabled`: probe before reading, because
    /// `value(forKey:)` on a retired key raises uncatchably — and halt rather than
    /// record, because `XCTFail` alone would let the read through.
    private func assertDeveloperExtras(_ expected: Bool, on webView: WKWebView,
                                       _ message: String) {
        let key = SiteWebViewFactory.developerExtrasPreferenceKey
        let preferences = webView.configuration.preferences
        guard SiteWebViewFactory.respondsToSetter(for: key, on: preferences) else {
            XCTFail("\(key) is no longer a known WKPreferences key")
            return
        }
        XCTAssertEqual(preferences.value(forKey: key) as? Bool, expected, message)
    }

    /// Inspection is opt-in per wrap, and "off" has to mean both switches off:
    /// the preference that adds Inspect Element to the context menu, and the
    /// flag that lets Safari's Develop menu attach. Either left on exposes a
    /// page nobody asked to expose.
    func testMakeWebViewLeavesEveryInspectionSwitchOffByDefault() {
        let webView = SiteWebViewFactory.makeWebView(for: fixtureWrap(), messageHandler: StubHandler())
        assertDeveloperExtras(false, on: webView,
                              "Inspect Element must not appear unless the wrap allows it")
        if #available(macOS 13.3, *) {
            XCTAssertFalse(webView.isInspectable,
                           "Safari must not list the app in its Develop menu unless the wrap allows it")
        }
    }

    /// Enabling the toggle turns on both switches. They are not interchangeable:
    /// `isInspectable` alone — all the factory shipped for a while — permits
    /// remote attach from Safari but never puts Inspect Element in the page's
    /// own context menu, so a user flipping the toggle saw nothing happen.
    func testMakeWebViewTurnsOnBothInspectionSwitchesWhenTheWrapAllows() {
        var wrap = fixtureWrap()
        wrap.behavior.isWebInspectorEnabled = true
        let webView = SiteWebViewFactory.makeWebView(for: wrap, messageHandler: StubHandler())
        assertDeveloperExtras(true, on: webView,
                              "Inspect Element belongs in the context menu when the wrap allows it")
        if #available(macOS 13.3, *) {
            XCTAssertTrue(webView.isInspectable,
                          "Safari must be able to attach when the wrap allows it")
        }
    }

    /// The permission must follow an edit made while the site app runs: the
    /// controller applies changes with `setInspectionAllowed` on the web view
    /// already on screen, so the flip has to reach both switches there too.
    func testSetInspectionAllowedFlipsBothSwitchesOnAnExistingWebView() {
        let webView = SiteWebViewFactory.makeWebView(for: fixtureWrap(), messageHandler: StubHandler())

        SiteWebViewFactory.setInspectionAllowed(true, on: webView)
        assertDeveloperExtras(true, on: webView,
                              "a live permission edit must arm Inspect Element without a rebuild")
        if #available(macOS 13.3, *) {
            XCTAssertTrue(webView.isInspectable,
                          "a live permission edit must let Safari attach without a rebuild")
        }

        SiteWebViewFactory.setInspectionAllowed(false, on: webView)
        assertDeveloperExtras(false, on: webView,
                              "revoking the permission must remove Inspect Element again")
        if #available(macOS 13.3, *) {
            XCTAssertFalse(webView.isInspectable,
                           "revoking the permission must detach Safari again")
        }
    }
}

import XCTest
import WebKit
@testable import Wrapybara

/// The one testable part of the web-view factory: that a wrap's web view opts out
/// of macOS's hidden-page throttling, so a covered window doesn't freeze a
/// streaming page. The keys are undocumented WebKit preferences, so the test pins
/// both that they're set and that the keys are still the ones that exist.
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
        guard SiteWebViewFactory.respondsToThrottlingSetter(for: key, on: preferences) else {
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
}

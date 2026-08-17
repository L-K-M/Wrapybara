import XCTest
import WebKit
@testable import Wrapybara

/// The one testable part of the web-view factory: that a wrap's web view opts out
/// of macOS's hidden-page throttling, so a covered window doesn't freeze a
/// streaming page. The keys are undocumented WebKit preferences, so the test pins
/// both that they're set and that the keys are still the ones that exist.
final class SiteWebViewFactoryTests: XCTestCase {

    /// Runs the factory against a fresh configuration and asserts `key` is present
    /// and false. `value(forKey:)` on a key WebKit no longer knows raises an
    /// uncatchable `NSUndefinedKeyException`, so the same `responds(to:)` probe
    /// production uses comes first — a retired key fails readably rather than
    /// crashing the test runner.
    private func assertThrottlingDisabled(_ key: String) {
        let configuration = WKWebViewConfiguration()
        SiteWebViewFactory.preventHiddenPageThrottling(configuration)
        let preferences = configuration.preferences
        XCTAssertTrue(preferences.responds(to: NSSelectorFromString("_\(key)")),
                      "\(key) is no longer a known WKPreferences key")
        XCTAssertFalse(preferences.value(forKey: key) as? Bool ?? true)
    }

    func testHiddenPageTimerThrottlingIsDisabled() {
        assertThrottlingDisabled("hiddenPageDOMTimerThrottlingEnabled")
    }

    func testHiddenPageThrottlingDoesNotAutoIncrease() {
        assertThrottlingDisabled("hiddenPageDOMTimerThrottlingAutoIncreases")
    }

    func testPageVisibilityBasedProcessSuppressionIsDisabled() {
        assertThrottlingDisabled("pageVisibilityBasedProcessSuppressionEnabled")
    }

    /// Every key in the list must be one the running WebKit actually knows — a key
    /// WebKit stops recognising would crash `setValue` at runtime, so this guards
    /// against the list silently going stale.
    func testEveryConfiguredKeyExistsOnThisWebKit() {
        let configuration = WKWebViewConfiguration()
        for key in SiteWebViewFactory.hiddenPageThrottlingPreferenceKeys {
            XCTAssertTrue(configuration.preferences.responds(to: NSSelectorFromString("_\(key)")),
                          "\(key) is no longer a known WKPreferences key")
        }
    }
}

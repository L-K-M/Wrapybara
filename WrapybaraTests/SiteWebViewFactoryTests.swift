import XCTest
import WebKit
@testable import Wrapybara

/// The one testable part of the web-view factory: that a wrap's web view opts out
/// of macOS's hidden-page throttling, so a covered window doesn't freeze a
/// streaming page. The keys are undocumented WebKit preferences, so the test pins
/// both that they're set and that the keys are still the ones that exist.
final class SiteWebViewFactoryTests: XCTestCase {

    private func configuredPreferences() -> WKPreferences {
        let configuration = WKWebViewConfiguration()
        SiteWebViewFactory.preventHiddenPageThrottling(configuration)
        return configuration.preferences
    }

    func testHiddenPageTimerThrottlingIsDisabled() {
        let preferences = configuredPreferences()
        XCTAssertFalse(preferences.value(forKey: "hiddenPageDOMTimerThrottlingEnabled") as? Bool ?? true)
    }

    func testHiddenPageThrottlingDoesNotAutoIncrease() {
        let preferences = configuredPreferences()
        XCTAssertFalse(preferences.value(forKey: "hiddenPageDOMTimerThrottlingAutoIncreases") as? Bool ?? true)
    }

    func testPageVisibilityBasedProcessSuppressionIsDisabled() {
        let preferences = configuredPreferences()
        XCTAssertFalse(preferences.value(forKey: "pageVisibilityBasedProcessSuppressionEnabled") as? Bool ?? true)
    }

    /// Every key in the list must be one the running WebKit actually knows — a key
    /// WebKit stops recognising would crash `setValue` at runtime, so this guards
    /// against the list silently going stale.
    func testEveryConfiguredKeyExistsOnThisWebKit() {
        let configuration = WKWebViewConfiguration()
        for key in SiteWebViewFactory.hiddenPageThrottlingPreferenceKeys {
            XCTAssertNotNil(configuration.preferences.value(forKey: key),
                            "\(key) is no longer a known WKPreferences key")
        }
    }
}

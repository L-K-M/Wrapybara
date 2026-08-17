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
    /// uncatchable `NSUndefinedKeyException`, so the same setter probe production
    /// uses comes first — and it has to halt execution, because `XCTAssertTrue`
    /// only records a failure and would let the read through.
    private func assertThrottlingDisabled(_ key: String) {
        let configuration = WKWebViewConfiguration()
        SiteWebViewFactory.preventHiddenPageThrottling(configuration)
        let preferences = configuration.preferences
        guard preferences.responds(to: NSSelectorFromString(SiteWebViewFactory.setterName(for: key))) else {
            XCTFail("\(key) is no longer a known WKPreferences key")
            return
        }
        XCTAssertFalse(preferences.value(forKey: key) as? Bool ?? true)
    }

    /// Every key the factory opts out of must actually be set false. Iterating the
    /// production list rather than hardcoding keys means a fourth key added to
    /// `hiddenPageThrottlingPreferenceKeys` is asserted automatically — and the
    /// guard above fails loudly if a key WebKit has retired was never set.
    func testAllConfiguredThrottlingKeysAreDisabled() {
        for key in SiteWebViewFactory.hiddenPageThrottlingPreferenceKeys {
            assertThrottlingDisabled(key)
        }
    }
}

import XCTest
@testable import Wrapybara

/// A site-app window must report its visibility honestly. WebKit reads
/// `NSWindow.isVisible` (and the window's occlusion state) to decide whether the
/// page is visible, and the hidden ↔ visible transitions become the page's
/// `visibilitychange` events — the signal a web app uses to resynchronise when the
/// user comes back. An earlier fix subclassed the window to claim visibility
/// forever; that kept `document.hidden` false for the page's whole life, so a
/// stream that died while the user was away (system sleep cuts every TCP
/// connection) was never followed by the site's own became-visible catch-up, and
/// the page stayed frozen on old state until a manual reload. These tests pin the
/// honest answers so that override can't quietly come back.
final class SiteWindowTests: XCTestCase {

    private func makeController() -> SiteWindowController {
        let configuration = WrapConfiguration(
            wrap: Wrap(name: "Test", homeURL: URL(string: "https://a.test")!,
                       bundleIdentifier: "com.example.test"),
            boosts: [], generatedBy: "tests")
        return SiteWindowController(configuration: configuration,
                                    downloads: DownloadCoordinator())
    }

    /// A window that has never been ordered in is not visible and must say so —
    /// the answer a plain `NSWindow` gives. The old override reported true here,
    /// which is exactly the lie that froze pages.
    func testUnshownWindowReportsItselfInvisible() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible,
                       "an unshown window must not claim to be visible to WebKit")
    }

    /// Ordering out — what hiding the app with ⌘H and parking a native tab in the
    /// background both do to a window — must read invisible again. That falling
    /// edge is what lets WebKit mark the page hidden, and the matching rising edge
    /// on re-show is what fires the `visibilitychange` a site catches up on.
    func testOrderedOutWindowReportsItselfInvisible() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible,
                       "an ordered-out window must not claim to be visible to WebKit")
        window.close()
    }
}

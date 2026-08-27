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
    /// Skipped where showing never took: without WindowServer cooperation the
    /// window was invisible throughout and the assertion would hold vacuously.
    func testOrderedOutWindowReportsItselfInvisible() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        // Mirrors makeWindow rather than trusting it: with AppKit's default `true`,
        // close() releases the window under these strong references mid-test.
        window.isReleasedWhenClosed = false
        // Deferred so the skip path cleans up too — XCTSkipUnless throws.
        defer { window.close() }
        window.orderFrontRegardless()
        try XCTSkipUnless(window.isVisible,
                          "no WindowServer cooperation; premise unpinned here")
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible,
                       "an ordered-out window must not claim to be visible to WebKit")
    }

    /// The other half of honesty: a *shown* window must answer visible, or the
    /// page would read hidden for its whole life — the mirror image of the lie
    /// this file exists to keep out. A plain-window control pins the premise
    /// first, so a headless environment skips rather than passing vacuously.
    func testShownWindowReportsItselfVisible() throws {
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        plain.orderFrontRegardless()
        defer { plain.close() }
        try XCTSkipUnless(plain.isVisible,
                          "no WindowServer cooperation; premise unpinned here")

        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        // Mirrors makeWindow; see the sibling test for why.
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible,
                      "a shown window must report itself visible to WebKit")
    }
}

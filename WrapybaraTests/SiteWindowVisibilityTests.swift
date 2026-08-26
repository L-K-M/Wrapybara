import AppKit
import XCTest
@testable import Wrapybara

/// Site-app windows must answer `isVisible` honestly. WebKit reads
/// `-[NSWindow isVisible]` (in `PageClientImpl::isViewVisible`) to decide whether
/// the page is visible, and the page must see the truth: the hidden→visible
/// transition is what fires `visibilitychange`, which is the signal a streaming
/// site uses to notice a silently dead connection (system sleep, a proxy idle
/// timeout, a network change) and resynchronize. An earlier revision shipped a
/// window subclass that reported itself visible for its whole open life; the pages
/// inside never saw a single `visibilitychange` and could never catch up after
/// their stream died — the "app stopped updating until reload" bug. These tests
/// pin the honesty so that subclass cannot quietly come back.
final class SiteWindowVisibilityTests: XCTestCase {

    private func makeController() -> SiteWindowController {
        let configuration = WrapConfiguration(
            wrap: Wrap(name: "Test", homeURL: URL(string: "https://a.test")!,
                       bundleIdentifier: "com.example.test"),
            boosts: [], generatedBy: "tests")
        return SiteWindowController(configuration: configuration,
                                    downloads: DownloadCoordinator())
    }

    /// A window nobody has shown yet reads invisible — the plain `NSWindow`
    /// answer, which is the one WebKit must keep hearing.
    func testControllerWindowAnswersVisibilityHonestlyBeforeShowing() throws {
        // The controller stays alive for the read: the window being measured is
        // the one production configures, not one orphaned by its owner's deinit.
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        XCTAssertFalse(window.isVisible,
                       "an unshown site-app window must not claim to be visible")
    }

    /// Ordering out — what hiding the app with ⌘H and parking a native tab behind
    /// the selected one both do to a window — must read invisible again. That
    /// transition is exactly the one WebKit turns into `visibilitychange`, and it
    /// is the page's only way to learn it was ever away.
    func testControllerWindowAnswersVisibilityHonestlyWhenOrderedOut() throws {
        let controller = makeController()
        let window = try XCTUnwrap(controller.window)
        window.orderFrontRegardless()
        defer { window.close() }
        // Headless test environments may not have a WindowServer to talk to; the
        // honesty can only be pinned where showing the window actually worked.
        try XCTSkipUnless(window.isVisible,
                          "no WindowServer cooperation; nothing to pin here")
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible,
                       "an ordered-out site-app window must not claim to be visible")
        // The other half of the signal: coming back must read visible again —
        // that transition is the one WebKit turns into the hidden→visible
        // `visibilitychange` a dead stream resynchronizes on.
        window.orderFrontRegardless()
        XCTAssertTrue(window.isVisible,
                      "a re-shown site-app window must report itself visible again")
    }
}

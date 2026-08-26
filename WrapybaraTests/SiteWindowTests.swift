import XCTest
@testable import Wrapybara

/// A site-app window has to report itself visible to WebKit for as long as the app
/// owns it — while the app is hidden with ⌘H (every window orders out), and while
/// it is a native tab sitting behind the selected one (sibling tab windows are
/// ordered out). Those are the states where `-[NSWindow isVisible]` says no,
/// `PageClientImpl::isViewVisible` believes it, and the page is marked hidden:
/// requestAnimationFrame suspends, the CSS/SVG animation timelines stop, and
/// `visibilitychange` invites a streaming page to tear its own connection down —
/// the "the app stopped updating" bug. A miniaturised window is *not* such a
/// state: it stays ordered in, so `isVisible` keeps answering yes and its page is
/// kept alive by the occlusion opt-out in `SiteWebViewFactory`. Once the window
/// closes, reporting goes back to being honest, so AppKit's quit-on-last-close and
/// Dock-reopen logic keep seeing the truth.
final class SiteWindowTests: XCTestCase {

    private func makeSiteWindow() -> SiteWindow {
        let window = SiteWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                                styleMask: [.titled], backing: .buffered, defer: false)
        // As production builds them (`SiteWindowController.makeWindow`). With the
        // default `true`, `-close()` releases the window mid-test and everything
        // read afterwards answers from freed memory.
        window.isReleasedWhenClosed = false
        return window
    }

    /// The honest-fixture half: a plain NSWindow that was never ordered in reports
    /// invisible — which is exactly the answer that makes WebKit hide a wrapped
    /// page. If a future macOS ever reports true here, the premise of
    /// `SiteWindow.isVisible` changed and these tests need rethinking with it.
    func testPlainUnshownWindowIsNotVisible() {
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        XCTAssertFalse(plain.isVisible)
    }

    /// The premise that decides what SiteWindow must cover: a miniaturised window
    /// stays ordered in, so AppKit still calls it visible — its page went dark only
    /// through the occlusion term WebKit consults after this one. If a future macOS
    /// starts reporting miniaturised windows as invisible here, that check moved,
    /// and `SiteWindow`'s coverage has to be rethought with it.
    func testMiniaturizedPlainWindowIsStillVisible() throws {
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled, .miniaturizable], backing: .buffered,
                             defer: false)
        plain.orderFrontRegardless()
        plain.miniaturize(nil)
        // Headless test environments may not have a WindowServer to talk to; the
        // premise is only pinned where miniaturising actually happened.
        try XCTSkipUnless(plain.isMiniaturized,
                          "no WindowServer cooperation; premise unpinned here")
        XCTAssertTrue(plain.isVisible)
    }

    func testUnshownSiteWindowReportsVisible() {
        XCTAssertTrue(makeSiteWindow().isVisible)
    }

    func testSiteWindowReportsInvisibleAgainOnceClosed() {
        let window = makeSiteWindow()
        XCTAssertTrue(window.isVisible)

        // The real close path, not a simulated notification: the honest answer has
        // to be in place before any observer of the close can look.
        window.close()
        XCTAssertFalse(window.isVisible)
    }

    /// The wiring end to end: the window a site-app controller installs IS a
    /// `SiteWindow`, live while owned, honest once its close begins.
    func testWindowControllerInstallsALiveSiteWindow() throws {
        let configuration = WrapConfiguration(
            wrap: Wrap(name: "Test", homeURL: URL(string: "https://a.test")!,
                       bundleIdentifier: "com.example.test"),
            boosts: [], generatedBy: "tests")
        let controller = SiteWindowController(configuration: configuration,
                                              downloads: DownloadCoordinator())
        let window = try XCTUnwrap(controller.window as? SiteWindow)
        XCTAssertTrue(window.isVisible)

        window.close()
        XCTAssertFalse(window.isVisible)
    }
}

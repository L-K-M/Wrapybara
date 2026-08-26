import XCTest
@testable import Wrapybara

/// A site-app window has to report itself visible to WebKit for as long as the app
/// owns it — including while it is miniaturised, while the app is hidden with ⌘H,
/// and while it is a native tab sitting behind the selected one. Those are the
/// states where `-[NSWindow isVisible]` says no, `PageClientImpl::isViewVisible`
/// believes it, and the page is marked hidden: requestAnimationFrame suspends, the
/// CSS/SVG animation timelines stop, and `visibilitychange` invites a streaming
/// page to tear its own connection down — the "the app stopped updating" bug.
/// Once the window closes, reporting goes back to being honest, so AppKit's
/// quit-on-last-close and Dock-reopen logic keep seeing the truth.
final class SiteWindowTests: XCTestCase {

    private func makeSiteWindow() -> SiteWindow {
        SiteWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                   styleMask: [.titled], backing: .buffered, defer: false)
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

    func testUnshownSiteWindowReportsVisible() {
        XCTAssertTrue(makeSiteWindow().isVisible)
    }

    func testSiteWindowReportsInvisibleAgainOnceClosed() {
        let window = makeSiteWindow()
        XCTAssertTrue(window.isVisible)

        // What closing looks like from the window's side: the will-close
        // notification. Posted directly so the test pins SiteWindow's own contract
        // without dragging half of AppKit's close machinery into it.
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
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

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        XCTAssertFalse(window.isVisible)
    }
}

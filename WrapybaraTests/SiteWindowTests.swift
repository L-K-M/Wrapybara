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

    private func makePlainWindow() -> NSWindow {
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        return plain
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
        plain.isReleasedWhenClosed = false
        plain.orderFrontRegardless()
        defer { plain.close() }
        plain.miniaturize(nil)
        // Headless test environments may not have a WindowServer to talk to; the
        // premise is only pinned where miniaturising actually happened.
        try XCTSkipUnless(plain.isMiniaturized,
                          "no WindowServer cooperation; premise unpinned here")
        XCTAssertTrue(plain.isVisible)
    }

    /// The premise for the ⌘H case: ordering out is what hiding does to a window,
    /// and an ordered-out window reads invisible to WebKit just like an unshown one.
    func testOrderedOutPlainWindowIsNotVisible() throws {
        let plain = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        plain.isReleasedWhenClosed = false
        plain.orderFrontRegardless()
        defer { plain.close() }
        try XCTSkipUnless(plain.isVisible,
                          "no WindowServer cooperation; premise unpinned here")
        plain.orderOut(nil)
        XCTAssertFalse(plain.isVisible)
    }

    /// The ⌘H case itself: an owned window that has been ordered out must still
    /// answer visible — that is the whole point of `SiteWindow`.
    func testOrderedOutSiteWindowStillReportsVisible() {
        let window = makeSiteWindow()
        defer { window.close() }
        window.orderFrontRegardless()
        window.orderOut(nil)
        XCTAssertTrue(window.isVisible)

        // Closing is what hands honesty back, even from the ordered-out state.
        window.close()
        XCTAssertFalse(window.isVisible)

        // The safety net: a closed window shown again is owned again.
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.isVisible)
    }

    /// The second headline state: a native tab parked behind the selected one.
    /// Whichever tab ends up in the background must still answer visible. Skipped
    /// where no tab group forms, and a plain-window control pair pins the
    /// premise that a background tab reads invisible without the override.
    func testTabGroupSiteWindowsStillReportVisible() throws {
        let previousTabbing = NSWindow.allowsAutomaticWindowTabbing
        NSWindow.allowsAutomaticWindowTabbing = true
        defer { NSWindow.allowsAutomaticWindowTabbing = previousTabbing }

        let selected = makeSiteWindow()
        let background = makeSiteWindow()
        selected.tabbingIdentifier = "site-tab-pair"
        background.tabbingIdentifier = "site-tab-pair"
        selected.orderFrontRegardless()
        selected.addTabbedWindow(background, ordered: .below)
        defer {
            background.close()
            selected.close()
        }

        try XCTSkipUnless(selected.tabbedWindows?.contains(background) == true,
                          "no tab group formed here; premise unpinned")

        // Control pair: a *plain* window parked behind the selected tab must read
        // invisible, or this test can't tell the override working from the
        // premise having moved out from under it.
        let plainSelected = makePlainWindow()
        let plainBackground = makePlainWindow()
        plainSelected.tabbingIdentifier = "plain-tab-pair"
        plainBackground.tabbingIdentifier = "plain-tab-pair"
        plainSelected.orderFrontRegardless()
        plainSelected.addTabbedWindow(plainBackground, ordered: .below)
        defer {
            plainBackground.close()
            plainSelected.close()
        }
        try XCTSkipUnless(
            plainSelected.tabbedWindows?.contains(plainBackground) == true,
            "control tab group did not form; premise unpinned")
        // Without WindowServer cooperation nothing here is visible and the
        // assertion below would hold vacuously.
        try XCTSkipUnless(plainSelected.isVisible,
                          "no WindowServer cooperation; premise unpinned here")
        XCTAssertFalse(plainBackground.isVisible)

        XCTAssertTrue(selected.isVisible)
        XCTAssertTrue(background.isVisible)
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

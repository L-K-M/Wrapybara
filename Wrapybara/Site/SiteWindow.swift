import AppKit

/// The window a generated site app runs its page in.
///
/// WebKit decides a page is hidden — suspending `requestAnimationFrame`, stopping
/// the CSS and SVG animation timelines, and firing `visibilitychange`, which
/// invites a streaming page to tear its own connection down — whenever
/// `PageClientImpl::isViewVisible` says so. That method reads `-[NSWindow isVisible]`
/// live, and that property answers no for two states a wrap reaches while the app
/// itself is still frontmost: the app is hidden with ⌘H (every window orders out),
/// and the window is a native tab sitting behind the selected one (its sibling
/// windows are ordered out). Miniaturising is *not* such a state — a miniaturised
/// window stays ordered in, so `isVisible` keeps answering yes, and its page used
/// to go dark only through the occlusion term that `SiteWebViewFactory` already
/// gates off. No WebKit switch reaches the `isVisible` check itself, so the window
/// answers for it: for as long as the app owns the window, `isVisible` reports
/// visible.
///
/// The cost is battery — the same trade-off keeping a covered window's page running
/// already makes, answered the same way: a wrap is the whole app, not a background
/// tab. Closed windows go back to answering honestly, because AppKit's
/// quit-on-last-close and click-the-Dock-icon-to-reopen logic consult visibility
/// too, and those must keep seeing the truth. There is deliberately no re-arm: the
/// reopen path never re-shows a closed window, it builds a fresh `SiteWindow`.
final class SiteWindow: NSWindow {

    /// False from the moment the window's close begins; flips `isVisible` back to
    /// the inherited, honest answer.
    private var keepsPageLive = true

    override var isVisible: Bool { keepsPageLive ? true : super.isVisible }

    /// Flips *before* `super.close()` posts `willCloseNotification`: observers of
    /// that notification run in unspecified order, and AppKit's own bookkeeping may
    /// consult visibility ahead of anything this window could react with. The
    /// honest answer has to be in place when the close becomes observable, not only
    /// in reaction to it.
    override func close() {
        keepsPageLive = false
        super.close()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SiteWindow is created in code, not from a nib")
    }
}

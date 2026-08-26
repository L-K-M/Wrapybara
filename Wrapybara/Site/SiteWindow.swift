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
/// too, and those must keep seeing the truth. Re-shown windows re-arm: today's
/// reopen path always builds a fresh `SiteWindow`, but if a future path ever
/// orders a closed one back in, honesty must not outlive it. A created-but-never-
/// shown window answers visible as well — safe because the app presents every
/// window it creates within the same turn, and its reopen logic keys off the
/// controller list rather than off visibility.
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

    /// Safety net for a path today's app never takes: a closed window ordered in
    /// again must re-arm, or its page reads hidden to WebKit forever — the very
    /// bug this class exists to fix. Re-arming on `order(_:relativeTo:)` catches
    /// every programmatic re-show (`orderFront`, `orderFrontRegardless`, tabbing);
    /// `makeKeyAndOrderFront` stays for AppKit paths that bypass the primitive.
    /// For a live window both are no-ops (already true).
    override func order(_ place: NSWindow.OrderingMode, relativeTo otherWindow: Int) {
        if place != .out { keepsPageLive = true }
        super.order(place, relativeTo: otherWindow)
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        keepsPageLive = true
        super.makeKeyAndOrderFront(sender)
    }

    /// Re-declared rather than inherited: defining `init?(coder:)` below stops
    /// Swift from passing `NSWindow`'s designated initializers down, and this is
    /// the one every site-app window is built through.
    override init(contentRect: NSRect, styleMask styleMask: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask,
                   backing: backingStoreType, defer: flag)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SiteWindow is created in code, not from a nib")
    }
}

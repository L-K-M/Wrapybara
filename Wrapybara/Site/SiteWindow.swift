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

    override init(contentRect: NSRect, styleMask styleMask: NSWindow.StyleMask,
                  backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask,
                   backing: backingStoreType, defer: flag)
        // Object-scoped, so only this window's close clears the flag. Observers
        // pairing a target with macOS 10.11+ need no explicit deregistration.
        NotificationCenter.default.addObserver(
            self, selector: #selector(stopKeepingPageLive),
            name: Self.willCloseNotification, object: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SiteWindow is created in code, not from a nib")
    }

    @objc private func stopKeepingPageLive() {
        keepsPageLive = false
    }
}

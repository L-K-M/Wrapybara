import WebKit
import os

/// Builds the `WKWebView` a site app runs in.
///
/// Everything about the configuration follows from one goal: the web view should
/// behave the way Safari's does, because that's what "native" means to someone who
/// has used a Mac. So: the system data store (which a per-bundle-identifier app gets
/// its own copy of, and which is what gives each wrap its own logins), WebKit's own
/// user agent unless the wrap overrides it, back/forward swipe, pinch magnification,
/// and inline media.
enum SiteWebViewFactory {

    /// A fixed subsystem across every wrap, so the retired-key diagnostic can be
    /// filtered in Console no matter which app the binary was copied into.
    private static let logger = Logger(subsystem: "Wrapybara", category: "SiteWebViewFactory")

    /// The `WKPreferences` keys that make a hidden page stop throttling.
    ///
    /// macOS treats a wrap whose window is covered, miniaturised, on another
    /// Space, or behind a sleeping display as "hidden", and WebKit then throttles
    /// the page's DOM timers to about once a second — and after a delay suspends
    /// the WebContent process entirely. A streaming chat is driven by timers, so
    /// the moment its window is covered it stops updating even though the server
    /// is still sending; and once the process is suspended the stream dies with
    /// no recovery short of a reload. Safari can afford that for a background
    /// tab; a wrap is the whole app, so it should keep running the way a native
    /// app does.
    ///
    /// These are the undocumented preferences Playwright, Bun and MacPin set for
    /// exactly this reason (they're the WebKit-internal controls for hidden-page
    /// throttling). Set through KVC because they carry a leading underscore and
    /// so have no public Swift surface. Precedent, for anyone re-checking later:
    /// Playwright sets all three in `browser_patches/webkit/embedder/Playwright/
    /// mac/AppDelegate.m`, Bun the process-suppression key in `src/runtime/
    /// webview/ObjCRuntime.cpp`, and MacPin — a similar site-wrapper — declares
    /// them in `modules/WebKitPrivates/WKPreferencesPrivate.h`.
    static let hiddenPageThrottlingPreferenceKeys = [
        "hiddenPageDOMTimerThrottlingEnabled",
        "hiddenPageDOMTimerThrottlingAutoIncreases",
        "pageVisibilityBasedProcessSuppressionEnabled",
    ]

    /// The `set<Key>:` (or `_set<Key>:`) selector KVC resolves for `key`.
    ///
    /// `setValue(_:forKey:)` looks for `set<Key>:` first and falls back to
    /// `_set<Key>:`. These keys expose only the underscored form. The trailing
    /// colon matters: a setter takes an argument, so its selector is
    /// `_setHiddenPageDOMTimerThrottlingEnabled:`, not `...Enabled`.
    static func setterSelector(for key: String, underscored: Bool) -> Selector {
        NSSelectorFromString((underscored ? "_set" : "set")
            + key.prefix(1).uppercased() + key.dropFirst() + ":")
    }

    /// Whether `object` can be written with `setValue(_:forKey:)` for `key` without
    /// raising.
    ///
    /// A key WebKit has retired raises an uncatchable `NSUndefinedKeyException`
    /// from `setValue`, so probe before calling it — probe true guarantees the
    /// write won't throw, probe false means skip. Shared with the tests so
    /// production and CI can't drift. Takes an `NSObject` rather than a
    /// `WKPreferences` because the same probe guards the `WKWebView` key below.
    static func respondsToSetter(for key: String, on object: NSObject) -> Bool {
        object.responds(to: setterSelector(for: key, underscored: false))
            || object.responds(to: setterSelector(for: key, underscored: true))
    }

    /// Opts `configuration` out of macOS's hidden-page throttling.
    ///
    /// The trade-off is battery: a hidden wrap keeps running its page's timers,
    /// which is precisely the point. The keys are undocumented but have been
    /// stable since macOS 10.12 and are the same ones Playwright, Bun and MacPin
    /// set. A key WebKit has since retired is skipped rather than crashing every
    /// wrap at launch — a retired key is exactly what
    /// `testAllConfiguredThrottlingKeysAreDisabled` is there to catch in CI,
    /// loudly, before a release.
    static func preventHiddenPageThrottling(_ configuration: WKWebViewConfiguration) {
        for key in hiddenPageThrottlingPreferenceKeys {
            guard respondsToSetter(for: key, on: configuration.preferences) else {
                // A user whose macOS retired a key would otherwise silently get the
                // throttling back — this log line is how that becomes a diagnosis.
                // Unified logging so it can be filtered by subsystem/category when
                // it comes back from a user's machine.
                logger.warning("WebKit no longer knows \(key, privacy: .public); hidden-page throttle opt-out incomplete")
                continue
            }
            configuration.preferences.setValue(false, forKey: key)
        }
    }

    /// The `WKWebView` key that stops a *covered* window from marking its page hidden.
    ///
    /// The preferences above lift timer throttling and WebKit's own process
    /// suppression, but neither touches the thing that actually stalls a streaming
    /// page: whether WebKit considers the page *visible*. On macOS that is decided
    /// by `PageClientImpl::isViewVisible`, which is false when the view has no
    /// window, when the view is hidden, when `NSWindow.isVisible` is false, **or**
    /// when the window's occlusion state has lost `NSWindowOcclusionStateVisible` —
    /// which is what happens the moment another app's window covers the wrap, the
    /// user switches Space, or the display sleeps.
    ///
    /// Losing visibility runs `Page::setIsVisibleInternal(false)` in the web content
    /// process, and that does three things a chat page cannot survive:
    /// `suspendScriptedAnimations()` stops `requestAnimationFrame`, the document
    /// timelines suspend CSS and SVG animation (so a "working on it" spinner stops
    /// mid-throb), and `visibilityStateChanged()` fires `visibilitychange` with
    /// `document.hidden` true — at which point the site's own code is entitled to
    /// tear its stream down, and typically does. The page is then stuck until it is
    /// reloaded: the reply the server finished writing never arrives, and only a
    /// reload fetches it. That is the "the app stopped updating" report, and the
    /// throttling keys alone never addressed it.
    ///
    /// `_windowOcclusionDetectionEnabled` is WebKit's own opt-out. False drops the
    /// occlusion term from that test, so a wrap whose window is merely covered keeps
    /// a visible page: animations keep running, `visibilitychange` never fires, and
    /// the stream stays up. It carries no availability annotation in
    /// `WKWebViewPrivate.h` (it has been there since 2015), and WebKit sets it false
    /// itself in the base system — for the same reason, that stale occlusion state
    /// makes pages misbehave.
    ///
    /// What this deliberately does *not* cover: a miniaturised window, or one hidden
    /// with ⌘H. Both make `NSWindow.isVisible` false, which WebKit checks before it
    /// ever consults occlusion, and no embedder switch reaches that. Those pages stop
    /// *painting*, but they keep running — timers unthrottled, process unsuppressed,
    /// App Nap held off — so the stream is still being read and the page catches up
    /// when the window comes back, instead of needing a reload.
    static let windowOcclusionDetectionKey = "windowOcclusionDetectionEnabled"

    /// Keeps a covered window's page in the visible state.
    ///
    /// See `windowOcclusionDetectionKey` for the mechanism and for the two cases it
    /// doesn't reach. The trade-off is the one `preventHiddenPageThrottling` already
    /// makes, answered the same way: a covered wrap keeps animating and keeps costing
    /// battery, because a wrap is the whole app rather than a background tab.
    ///
    /// Probed rather than set blind, for the reason the preference keys are: a key
    /// WebKit has retired raises an uncatchable `NSUndefinedKeyException`, and a wrap
    /// that freezes when covered is much better than one that crashes at launch.
    static func keepPageVisibleWhileWindowIsCovered(_ webView: WKWebView) {
        let key = windowOcclusionDetectionKey
        guard respondsToSetter(for: key, on: webView) else {
            // Same diagnostic contract as the throttling keys: a user whose macOS
            // retired this would otherwise just see the freeze come back.
            logger.warning("WebKit no longer knows \(key, privacy: .public); a covered window will hide its page")
            return
        }
        webView.setValue(false, forKey: key)
    }

    /// - Parameter handler: receives the page's messages — the picker's selection, the
    ///   notification shim's payloads, soft navigations.
    static func makeWebView(for wrap: Wrap,
                            messageHandler: WKScriptMessageHandler) -> WKWebView {
        let configuration = WKWebViewConfiguration()

        // Each generated app has its own bundle identifier, so `.default()` already
        // resolves to a WebKit directory of its own — which is exactly the isolation
        // that lets two wraps of the same site hold two different logins. Nothing
        // extra is needed, and using a non-persistent store here would silently sign
        // the user out on every quit.
        configuration.websiteDataStore = .default()

        preventHiddenPageThrottling(configuration)

        configuration.suppressesIncrementalRendering = false
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        // Sites that use `<video>` for animation break when it's forced fullscreen.
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        let content = configuration.userContentController
        for name in [BoostScripts.Handler.picker,
                     BoostScripts.Handler.notification,
                     BoostScripts.Handler.navigated] {
            content.add(messageHandler, name: name)
        }

        let webView = WKWebView(frame: .zero, configuration: configuration)
        // Before the view is ever put in a window, so the first activity state WebKit
        // computes for it already has occlusion out of the picture.
        keepPageVisibleWhileWindowIsCovered(webView)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        webView.allowsLinkPreview = true
        webView.customUserAgent = wrap.behavior.resolvedUserAgent
        webView.pageZoom = wrap.behavior.pageZoom

        // `underPageBackgroundColor` is deliberately left alone. WebKit derives it
        // from the page's own background, which is what stops rubber-band scrolling
        // on a dark site from flashing a white band — the single most obvious "this is
        // a web view in a box" tell. Setting it here would override that inference and
        // reintroduce the flash.

        if #available(macOS 13.3, *) {
            webView.isInspectable = wrap.behavior.isWebInspectorEnabled
        }

        return webView
    }
}

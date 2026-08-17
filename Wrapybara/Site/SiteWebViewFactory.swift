import WebKit

/// Builds the `WKWebView` a site app runs in.
///
/// Everything about the configuration follows from one goal: the web view should
/// behave the way Safari's does, because that's what "native" means to someone who
/// has used a Mac. So: the system data store (which a per-bundle-identifier app gets
/// its own copy of, and which is what gives each wrap its own logins), WebKit's own
/// user agent unless the wrap overrides it, back/forward swipe, pinch magnification,
/// and inline media.
enum SiteWebViewFactory {

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
    /// so have no public Swift surface.
    static let hiddenPageThrottlingPreferenceKeys = [
        "hiddenPageDOMTimerThrottlingEnabled",
        "hiddenPageDOMTimerThrottlingAutoIncreases",
        "pageVisibilityBasedProcessSuppressionEnabled",
    ]

    /// Opts `configuration` out of macOS's hidden-page throttling.
    ///
    /// The trade-off is battery: a hidden wrap keeps running its page's timers,
    /// which is precisely the point. The keys are undocumented but have been
    /// stable since macOS 10.12 and are the same ones Playwright, Bun and MacPin
    /// set. A key WebKit has since retired is skipped rather than crashing every
    /// wrap at launch — a retired key is exactly what `testEveryConfiguredKeyExistsOnThisWebKit`
    /// is there to catch in CI, loudly, before a release.
    static func preventHiddenPageThrottling(_ configuration: WKWebViewConfiguration) {
        for key in hiddenPageThrottlingPreferenceKeys {
            // `setValue(_:forKey:)` on a key the class no longer knows raises
            // `NSUndefinedKeyException`, which Swift cannot catch — probing the
            // private `_<key>` getter first is a reliable existence check that
            // cannot itself throw.
            guard configuration.preferences.responds(to: NSSelectorFromString("_\(key)")) else {
                // A user whose macOS retired a key would otherwise silently get the
                // throttling back — this log line is how that becomes a diagnosis.
                NSLog("Wrapybara: WebKit no longer knows \(key); hidden-page throttle opt-out incomplete")
                continue
            }
            configuration.preferences.setValue(false, forKey: key)
        }
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

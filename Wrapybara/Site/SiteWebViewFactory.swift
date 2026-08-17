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

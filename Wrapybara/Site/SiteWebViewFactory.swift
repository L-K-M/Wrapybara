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

    /// Where the liveness opt-outs deliberately stop: page *visibility* is never
    /// faked.
    ///
    /// Two earlier fixes went further than the keys above and made the page believe
    /// it was permanently visible — `_windowOcclusionDetectionEnabled` false on the
    /// web view, and a window subclass whose `isVisible` answered true while the
    /// window was hidden. That pinned `document.visibilityState` to `"visible"` for
    /// the page's whole life, so `visibilitychange` never fired — and that silenced
    /// the one signal a modern web app uses to *recover*. Streams die for reasons no
    /// embedder switch controls: system sleep cuts every TCP connection (this app
    /// deliberately allows idle sleep — see `SiteAppDelegate`), networks change,
    /// proxies and servers drop idle connections. A page in a real browser heals
    /// from all of that the moment the user comes back, because the hidden → visible
    /// transition — delivered on uncovering, un-minimising, unhiding, tab switch and
    /// display wake — is what triggers its refetch-on-focus / resubscribe path. A
    /// page that was never told it was hidden is never told it is visible again
    /// either; it just sits on whatever state it had when its connection died. That
    /// was the "the wrap stops updating until a manual reload" bug.
    ///
    /// So the policy is: keep the page *running* while hidden (the preference keys
    /// above, plus the App Nap assertion in `SiteAppDelegate`), and report
    /// visibility honestly the way Safari does. The site pauses what it chooses
    /// while hidden and — crucially — resyncs itself on every return, exactly as it
    /// does in the browser its authors tested in.

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

        setInspectionAllowed(wrap.behavior.isWebInspectorEnabled, on: webView)

        return webView
    }

    // MARK: Web Inspector

    /// The private `WKWebView` property holding WebKit's inspector handle, and the
    /// selectors that drive it.
    ///
    /// The public surface stops at *allowing* inspection; nothing public *raises*
    /// the inspector. These names are undocumented but have been stable for a
    /// decade, so they get the same contract as the throttling keys above:
    /// probed before use, skipped loudly when gone.
    private static let inspectorHandleKey = "_inspector"
    private static let inspectorVisibilityKey = "isVisible"
    private static let showInspectorSelector = NSSelectorFromString("show")
    private static let hideInspectorSelector = NSSelectorFromString("hide")
    private static let detachInspectorSelector = NSSelectorFromString("detach")

    /// Writes the wrap's inspector permission onto a web view.
    ///
    /// One setting, two switches, because each alone leaves one path dead:
    /// `developerExtrasEnabled` is what puts Inspect Element into the page's own
    /// right-click menu (the local inspector), while `isInspectable` is what lets
    /// Safari's Develop menu attach to the app's pages. Safe to write again while
    /// the app runs — WebKit pushes preference changes into the live process,
    /// which is what makes the toggle follow edits from Wrapybara without a
    /// rebuild or relaunch.
    static func setInspectionAllowed(_ allowed: Bool, on webView: WKWebView) {
        // A revocation takes down an inspector already up: WebKit closes only the
        // remote attach on its own, the local window would stay open.
        if !allowed { hideInspectorIfVisible(of: webView) }
        setDeveloperExtras(allowed, on: webView.configuration.preferences)
        if #available(macOS 13.3, *) {
            webView.isInspectable = allowed
        }
    }

    /// The `WKPreferences` key behind the context menu's Inspect Element.
    ///
    /// A macOS-only WebKit preference with no Swift surface in current SDKs —
    /// reachable only through KVC, so it rides the same probe-before-write
    /// contract as the throttling keys above.
    static let developerExtrasPreferenceKey = "developerExtrasEnabled"

    private static func setDeveloperExtras(_ allowed: Bool, on preferences: WKPreferences) {
        guard respondsToSetter(for: developerExtrasPreferenceKey, on: preferences) else {
            logger.warning("WebKit no longer knows \(developerExtrasPreferenceKey, privacy: .public); Inspect Element will not appear in context menus")
            return
        }
        preferences.setValue(allowed, forKey: developerExtrasPreferenceKey)
    }

    /// Whether raising the inspector can possibly work here.
    ///
    /// The View menu asks before validating its item, so a WebKit missing the
    /// machinery greys the entry out instead of offering a button that does
    /// nothing — and what it checks is exactly what `toggleInspector` will call.
    static func canToggleInspector(of webView: WKWebView) -> Bool {
        guard let inspector = inspectorObject(of: webView) else { return false }
        return inspector.responds(to: showInspectorSelector)
            && inspector.responds(to: hideInspectorSelector)
    }

    /// Raises the inspector in a window of its own — or closes it when showing,
    /// the way Safari's ⌥⌘I behaves.
    ///
    /// Detached on purpose. WebKit's other presentation is a panel *attached*
    /// inside the inspected view, and it is frame-managed: WebKit shrinks the web
    /// view to carve the panel out and observes the frame to keep it that way.
    /// This app's container pins the web view with Auto Layout, so every WebKit
    /// correction is undone by the next layout pass and re-made by WebKit's
    /// observer — the page and the panel flicker against each other forever.
    /// A window of WebKit's own never enters that fight.
    ///
    /// `show` may open either presentation, so `detach` runs right behind it:
    /// both calls share one run-loop turn, so an attached intermediate state is
    /// never drawn and the frame observer never fires. A WebKit without `detach`
    /// keeps whatever `show` opened.
    ///
    /// Returns whether anything happened, so a caller can stay quiet rather than
    /// beep at machinery that isn't there.
    @discardableResult
    static func toggleInspector(of webView: WKWebView) -> Bool {
        guard let inspector = inspectorObject(of: webView) else {
            logger.warning("WebKit no longer knows \(inspectorHandleKey, privacy: .public); the inspector cannot be raised from the menu bar")
            return false
        }

        let selector = isInspectorVisible(inspector)
            ? hideInspectorSelector : showInspectorSelector
        guard inspector.responds(to: selector) else {
            logger.warning("WebKit's inspector no longer answers \(NSStringFromSelector(selector), privacy: .public); Show Web Inspector cannot toggle")
            return false
        }
        inspector.perform(selector)

        if selector == showInspectorSelector,
           inspector.responds(to: detachInspectorSelector) {
            inspector.perform(detachInspectorSelector)
        }
        return true
    }

    /// Hides the inspector when it is up. Probed end to end, so a WebKit missing
    /// any piece of the handle makes revocation's tidy-up a quiet no-op.
    private static func hideInspectorIfVisible(of webView: WKWebView) {
        guard let inspector = inspectorObject(of: webView),
              isInspectorVisible(inspector),
              inspector.responds(to: hideInspectorSelector) else { return }
        inspector.perform(hideInspectorSelector)
    }

    /// Reads `_inspector`. Probed first because KVC on a key WebKit no longer
    /// knows raises an uncatchable exception — the same contract as the setter
    /// probes above.
    private static func inspectorObject(of webView: WKWebView) -> NSObject? {
        guard webView.responds(to: NSSelectorFromString(inspectorHandleKey)) else { return nil }
        return webView.value(forKey: inspectorHandleKey) as? NSObject
    }

    private static func isInspectorVisible(_ inspector: NSObject) -> Bool {
        inspector.responds(to: NSSelectorFromString(inspectorVisibilityKey))
            && ((inspector.value(forKey: inspectorVisibilityKey) as? Bool) ?? false)
    }
}

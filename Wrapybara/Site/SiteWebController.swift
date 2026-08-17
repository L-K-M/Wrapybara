import AppKit
// WebKit carries no `Sendable` annotations, so importing it normally warns on every
// delegate callback that crosses an isolation boundary. `@preconcurrency` is the
// documented suppression for a framework that predates strict concurrency.
@preconcurrency import WebKit

/// Owns one web view and everything that happens inside it.
///
/// Split from `SiteWindowController` so that window furniture (toolbar, find bar,
/// title, tabs) and web behaviour (navigation policy, boosts, downloads, page
/// messages) don't end up in one thousand-line class. The window observes this
/// through `SiteWebControllerDelegate`.
protocol SiteWebControllerDelegate: AnyObject {
    /// Any of title, URL, loading state or back/forward availability changed.
    func siteWebControllerDidChangeState(_ controller: SiteWebController)
    /// The page asked to open `url` somewhere else in this app.
    func siteWebController(_ controller: SiteWebController, openInNewTab url: URL)
    /// A `target="_blank"` needs a real web view to load into. Returning `nil`
    /// cancels the popup.
    func siteWebController(_ controller: SiteWebController,
                           webViewForPopupWith configuration: WKWebViewConfiguration) -> WKWebView?
    /// The element picker finished. `selector` is empty when cancelled.
    func siteWebController(_ controller: SiteWebController, didPickSelector selector: String)
    /// The page posted a notification through the shim.
    func siteWebController(_ controller: SiteWebController,
                           didPostNotification payload: NotificationBridge.Payload)
}

final class SiteWebController: NSObject {

    let webView: WKWebView
    weak var delegate: SiteWebControllerDelegate?

    private(set) var configuration: WrapConfiguration
    private var injector: BoostInjector
    private let downloads: DownloadCoordinator

    /// The URL the boosts currently installed on the web view were built for. Used to
    /// avoid rebuilding user scripts on every same-page fragment change.
    private var boostedURL: URL?
    /// The last main-frame URL this controller allowed a load for. After a
    /// provisional failure the web view still reports the *previous* page's URL,
    /// so the error page needs this to say what actually failed.
    private var lastRequestedURL: URL?
    private var observations: [NSKeyValueObservation] = []
    /// Retained so WebKit's script-message registration keeps working — see
    /// `ScriptMessageForwarder`.
    private var messageForwarder: ScriptMessageForwarder?

    var wrap: Wrap { configuration.wrap }

    init(configuration: WrapConfiguration, downloads: DownloadCoordinator) {
        self.configuration = configuration
        self.injector = BoostInjector(configuration: configuration)
        self.downloads = downloads
        // A placeholder handler is not needed: `SiteWebViewFactory` takes the handler
        // up front, and `self` isn't available until after `super.init()`. So the web
        // view is built with a small forwarding shim that holds a weak reference.
        let forwarder = ScriptMessageForwarder()
        self.webView = SiteWebViewFactory.makeWebView(for: configuration.wrap,
                                                      messageHandler: forwarder)
        super.init()
        forwarder.target = self
        self.messageForwarder = forwarder

        webView.navigationDelegate = self
        webView.uiDelegate = self
        observeWebView()
    }

    deinit {
        // WebKit keeps a strong reference to script message handlers; leaving them
        // registered would keep the forwarder (and through it this controller's web
        // view) alive after the window closes.
        let content = webView.configuration.userContentController
        for name in [BoostScripts.Handler.picker,
                     BoostScripts.Handler.notification,
                     BoostScripts.Handler.navigated] {
            content.removeScriptMessageHandler(forName: name)
        }
    }

    // MARK: Loading

    func loadHome() {
        load(wrap.homeURL)
    }

    func load(_ url: URL) {
        installBoosts(for: url)
        lastRequestedURL = url
        webView.load(URLRequest(url: url))
    }

    /// Restores a previous session's page, scroll offset and form state.
    ///
    /// `interactionState` carries the whole back-forward list, so this is a real
    /// "reopen where I was" rather than just re-loading a URL.
    func restore(interactionState: Data) -> Bool {
        installBoosts(for: wrap.homeURL)
        webView.interactionState = interactionState
        // WebKit ignores an unusable blob rather than throwing, so confirm something
        // actually happened before reporting success.
        return webView.url != nil || webView.isLoading
    }

    var interactionState: Data? { webView.interactionState as? Data }

    // MARK: Boosts

    /// Replaces the configuration — a boost was edited in Wrapybara while this app was
    /// running — and re-applies it to the page currently on screen.
    func apply(_ newConfiguration: WrapConfiguration) {
        configuration = newConfiguration
        injector = BoostInjector(configuration: newConfiguration)
        BoostMatcher.clearCache()
        boostedURL = nil
        if let url = webView.url {
            installBoosts(for: url)
            reapplyStylesheet(for: url)
        }
        webView.pageZoom = newConfiguration.wrap.behavior.pageZoom
        webView.customUserAgent = newConfiguration.wrap.behavior.resolvedUserAgent
        delegate?.siteWebControllerDidChangeState(self)
    }

    /// Rebuilds the web view's user scripts for `url`.
    ///
    /// Called before a load starts, so the `documentStart` stylesheet is in place
    /// before the page paints.
    private func installBoosts(for url: URL) {
        let content = webView.configuration.userContentController
        content.removeAllUserScripts()
        for script in injector.userScripts(for: url) {
            content.addUserScript(script)
        }
        boostedURL = url
    }

    /// Re-runs the stylesheet script against the live page, for a same-document
    /// navigation where no new load (and so no user script) happens.
    private func reapplyStylesheet(for url: URL) {
        webView.evaluateJavaScript(injector.stylesheetScript(for: url)) { _, error in
            if let error { NSLog("Wrapybara: re-applying boosts failed: \(error.localizedDescription)") }
        }
    }

    /// A description of which boosts are live on the current page.
    var boostSummary: String {
        injector.summary(for: webView.url ?? wrap.homeURL)
    }

    // MARK: Element picker

    /// Starts the Zap picker in the page.
    func beginPickingElement() {
        webView.evaluateJavaScript(BoostScripts.selectorBuilder) { [weak self] _, _ in
            self?.webView.evaluateJavaScript(BoostScripts.elementPicker, completionHandler: nil)
        }
    }

    // MARK: Actions

    func goBack() { webView.goBack() }
    func goForward() { webView.goForward() }
    func reload() { webView.reload() }
    func reloadIgnoringCache() { webView.reloadFromOrigin() }
    func stopLoading() { webView.stopLoading() }

    func setZoom(_ zoom: Double) {
        webView.pageZoom = max(0.25, min(5, zoom))
    }

    var zoom: Double { webView.pageZoom }

    /// A print operation for the current page, ready to run modally.
    func printOperation() -> NSPrintOperation {
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.isHorizontallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.view?.frame = webView.bounds
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        return operation
    }

    // MARK: Observation

    private func observeWebView() {
        // KVO rather than polling: WebKit publishes all of these, and the toolbar has
        // to track them without a timer.
        func observe<Value>(_ keyPath: KeyPath<WKWebView, Value>) {
            observations.append(webView.observe(keyPath, options: [.new]) { [weak self] _, _ in
                guard let self else { return }
                self.delegate?.siteWebControllerDidChangeState(self)
            })
        }
        observe(\.title)
        observe(\.url)
        observe(\.isLoading)
        observe(\.canGoBack)
        observe(\.canGoForward)
        observe(\.estimatedProgress)
    }
}

// MARK: - Navigation

extension SiteWebController: WKNavigationDelegate {

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow, preferences)
            return
        }

        // A sub-frame load is the page's own business — an ad, an embedded player, an
        // OAuth iframe. Sending those to the browser would break the page.
        guard navigationAction.targetFrame?.isMainFrame ?? true else {
            decisionHandler(.allow, preferences)
            return
        }

        let isUserInitiated: Bool
        switch navigationAction.navigationType {
        case .linkActivated, .formSubmitted, .formResubmitted, .backForward, .reload:
            isUserInitiated = true
        case .other:
            // `.other` covers both a script-driven navigation and a server redirect.
            // Treating it as user-initiated would send a login redirect chain to
            // Safari halfway through; treating it as not means it stays in the app.
            isUserInitiated = false
        @unknown default:
            isUserInitiated = false
        }

        let decision = NavigationPolicy.decide(
            for: url,
            inAppHosts: wrap.inAppHosts,
            policy: wrap.behavior.externalLinks,
            isUserInitiated: isUserInitiated,
            targetsNewWindow: navigationAction.targetFrame == nil)

        switch decision {
        case .allow:
            // The error page's own `loadHTMLString` arrives here as about:blank
            // (when WebKit consults policy for it): let it through without
            // churning the installed boosts — they were built for the failed URL
            // and are what styles the error page — and without clobbering the
            // tracked address we're about to need on the next failure.
            if url.absoluteString == "about:blank" {
                decisionHandler(.allow, preferences)
                return
            }
            if boostedURL != url { installBoosts(for: url) }
            lastRequestedURL = url
            decisionHandler(.allow, preferences)
        case .openInNewTab:
            decisionHandler(.cancel, preferences)
            delegate?.siteWebController(self, openInNewTab: url)
        case .openExternally:
            decisionHandler(.cancel, preferences)
            NSWorkspace.shared.open(url)
        case .block:
            decisionHandler(.cancel, preferences)
        }
    }

    func webView(_ webView: WKWebView,
                 decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Anything WebKit can't display becomes a download, the way Safari does —
        // otherwise clicking a PDF export link does nothing at all.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction,
                 didBecome download: WKDownload) {
        downloads.begin(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse,
                 didBecome download: WKDownload) {
        downloads.begin(download)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                 withError error: Error) {
        report(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        delegate?.siteWebControllerDidChangeState(self)
    }

    /// The web content process died. Reloading is the only recovery, and doing it
    /// silently is better than leaving a blank window the user has to work out.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        NSLog("Wrapybara: the web content process ended; reloading")
        webView.reload()
    }

    private func report(_ error: Error) {
        let nsError = error as NSError
        // Cancellation isn't a failure: it's what every `.cancel` policy decision and
        // every interrupted load looks like from here.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        NSLog("Wrapybara: navigation failed: \(error.localizedDescription)")
        delegate?.siteWebControllerDidChangeState(self)

        // Without this the failure leaves a blank white window. The page says what
        // went wrong and offers Try Again — an ordinary link, so the retry flows
        // through NavigationPolicy like any in-app click.
        guard SiteErrorPage.shouldShow(for: error) else { return }
        let failedURL = SiteErrorPage.failingURL(
            for: error,
            fallbacks: [lastRequestedURL, webView.url, wrap.homeURL]) ?? wrap.homeURL
        // baseURL about:blank keeps the page at an opaque origin rather than the
        // failed site's — nothing on it needs the site origin (the retry link is
        // absolute), and the page displays the failed address itself.
        webView.loadHTMLString(
            SiteErrorPage.html(wrapName: wrap.name, failedURL: failedURL,
                               error: error, tintHex: wrap.icon.tintHex),
            baseURL: URL(string: "about:blank"))
    }
}

// MARK: - UI delegate

extension SiteWebController: WKUIDelegate {

    func webView(_ webView: WKWebView,
                 createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // `window.open` and `target="_blank"`. If the target is outside the wrap and
        // the user chose "open in browser", honour that instead of making a tab.
        if let url = navigationAction.request.url,
           !NavigationPolicy.isInApp(url: url, inAppHosts: wrap.inAppHosts),
           wrap.behavior.externalLinks == .openInDefaultBrowser {
            NSWorkspace.shared.open(url)
            return nil
        }
        return delegate?.siteWebController(self, webViewForPopupWith: configuration)
    }

    func webViewDidClose(_ webView: WKWebView) {
        webView.window?.performClose(nil)
    }

    // MARK: JavaScript dialogs — as real sheets, not swallowed

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = wrap.name
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        present(alert) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = wrap.name
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in completionHandler(response == .alertFirstButtonReturn) }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = wrap.name
        alert.informativeText = prompt
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        present(alert) { response in
            completionHandler(response == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        guard let window = webView.window else {
            completionHandler(panel.runModal() == .OK ? panel.urls : nil)
            return
        }
        panel.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? panel.urls : nil)
        }
    }

    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // Only the wrap's own origins get to ask. Anything else is an embed, and a
        // camera prompt attributed to the app for a third-party frame would be
        // misleading about who is asking.
        let allowed = NavigationPolicy.isInApp(host: origin.host, inAppHosts: wrap.inAppHosts)
        // `.prompt` hands the decision to macOS, which shows the system TCC dialog
        // naming this app — the honest place for the choice to be made.
        decisionHandler(allowed ? .prompt : .deny)
    }

    private func present(_ alert: NSAlert, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard let window = webView.window else {
            completion(alert.runModal())
            return
        }
        alert.beginSheetModal(for: window, completionHandler: completion)
    }
}

// MARK: - Page messages

extension SiteWebController: WKScriptMessageHandler {

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        // Everything here came from the page, which may be running a boost's script or
        // the site's own. Each branch validates its payload rather than trusting it.
        switch message.name {
        case BoostScripts.Handler.picker:
            let selector = (message.body as? [String: Any])?["selector"] as? String ?? ""
            delegate?.siteWebController(self, didPickSelector: selector)

        case BoostScripts.Handler.notification:
            guard wrap.behavior.forwardsWebNotifications,
                  let payload = NotificationBridge.Payload(message.body) else { return }
            delegate?.siteWebController(self, didPostNotification: payload)

        case BoostScripts.Handler.navigated:
            guard let body = message.body as? [String: Any],
                  let urlString = body["url"] as? String,
                  let url = URL(string: urlString) else { return }
            // A single-page app moved without a load. Re-install for the next real
            // navigation and re-style the page that's already on screen.
            if boostedURL != url {
                installBoosts(for: url)
                reapplyStylesheet(for: url)
            }
            delegate?.siteWebControllerDidChangeState(self)

        default:
            break
        }
    }
}

// MARK: - Message forwarding

/// Breaks the retain cycle WebKit's script-message registration would otherwise
/// create.
///
/// `WKUserContentController` holds its handlers strongly, and the handler here is the
/// controller that owns the web view that owns the content controller. This shim sits
/// in the middle with a weak reference, so closing a window actually deallocates it.
private final class ScriptMessageForwarder: NSObject, WKScriptMessageHandler {
    weak var target: SiteWebController?

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

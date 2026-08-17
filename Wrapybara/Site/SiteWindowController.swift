import AppKit
import WebKit

/// One window of a site app: the toolbar, the find bar, the web view, and the window
/// state that has to survive a quit.
///
/// The furniture here is what the project is actually about. A `WKWebView` in a plain
/// window is what every wrapper ships; a unified toolbar with real `NSToolbarItem`s, a
/// native tab bar, a title that tracks the page, ⌘F that uses WebKit's own find, and a
/// window that reopens where it was — that's the difference.
final class SiteWindowController: NSWindowController, NSMenuItemValidation {

    let webController: SiteWebController
    private let findBar: FindBarController
    private let behavior: WrapBehavior
    private let wrapName: String

    /// Called when this window's web view wants a new tab.
    var onOpenInNewTab: ((URL, SiteWindowController) -> Void)?
    /// Called when a popup needs a window of its own to load into.
    var onNeedsPopupWindow: ((WKWebViewConfiguration, SiteWindowController) -> WKWebView?)?
    /// Called for a notification the page posted.
    var onNotification: ((NotificationBridge.Payload) -> Void)?
    /// Called whenever the page's title or URL changes, for the Dock badge and Handoff.
    var onPageChanged: ((SiteWindowController) -> Void)?

    /// Named `browsingActivity` rather than `userActivity`: `NSResponder` already has
    /// a property by that name, and shadowing it would be a trap for the next reader.
    private var browsingActivity: NSUserActivity?

    // MARK: Init

    init(configuration: WrapConfiguration, downloads: DownloadCoordinator) {
        // Built into a local first: Swift forbids reading `self`'s properties before
        // `super.init()`, so `self.webController.webView` here would not compile.
        let webController = SiteWebController(configuration: configuration, downloads: downloads)
        self.behavior = configuration.wrap.behavior
        self.wrapName = configuration.wrap.name
        self.webController = webController
        self.findBar = FindBarController(webView: webController.webView)

        let window = Self.makeWindow(for: configuration.wrap)
        super.init(window: window)

        window.delegate = self
        webController.delegate = self
        buildContentView()
        if behavior.chrome.showsToolbar { installToolbar() }
        window.title = configuration.wrap.name
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SiteWindowController is created in code, not from a nib")
    }

    private static func makeWindow(for wrap: Wrap) -> NSWindow {
        let size = NSSize(width: max(480, wrap.behavior.initialWindowWidth),
                          height: max(360, wrap.behavior.initialWindowHeight))
        var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        if wrap.behavior.chrome.hasTransparentTitleBar { style.insert(.fullSizeContentView) }

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: style, backing: .buffered, defer: false)
        window.minSize = NSSize(width: 400, height: 300)
        window.titlebarAppearsTransparent = wrap.behavior.chrome.hasTransparentTitleBar
        window.isReleasedWhenClosed = false
        // Native tabs. The identifier has to be shared by every window that may tab
        // together, and `automatic` respects the user's System Settings choice for when
        // to prefer tabs — which is the setting they already made for every other app.
        window.tabbingIdentifier = wrap.bundleIdentifier
        window.tabbingMode = wrap.behavior.allowsNativeTabs ? .automatic : .disallowed
        // Restore the frame per wrap rather than per window, so the first window of a
        // relaunch opens where the last one was.
        window.center()
        // After `center()`, so a previously saved frame wins over the default position.
        window.setFrameAutosaveName("SiteWindow")
        return window
    }

    // MARK: Content

    private func buildContentView() {
        let webView = webController.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        findBar.view.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(findBar.view)
        container.addSubview(webView)

        NSLayoutConstraint.activate([
            findBar.view.topAnchor.constraint(equalTo: container.topAnchor),
            findBar.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            findBar.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            webView.topAnchor.constraint(equalTo: findBar.view.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        window?.contentView = container
        window?.initialFirstResponder = webView
    }

    // MARK: Loading

    func loadHome() { webController.loadHome() }

    func load(_ url: URL) { webController.load(url) }

    /// Restores a saved session, falling back to the home page if the blob is stale.
    func restoreOrLoadHome(interactionState: Data?) {
        if let interactionState, webController.restore(interactionState: interactionState) { return }
        webController.loadHome()
    }

    var interactionState: Data? { webController.interactionState }

    func apply(_ configuration: WrapConfiguration) {
        webController.apply(configuration)
    }

    // MARK: Actions

    @objc func goBack(_ sender: Any?) { webController.goBack() }
    @objc func goForward(_ sender: Any?) { webController.goForward() }
    @objc func reloadPage(_ sender: Any?) { webController.reload() }
    @objc func reloadPageIgnoringCache(_ sender: Any?) { webController.reloadIgnoringCache() }
    @objc func stopLoading(_ sender: Any?) { webController.stopLoading() }
    @objc func goHome(_ sender: Any?) { webController.loadHome() }

    @objc func performFind(_ sender: Any?) { findBar.show() }
    @objc func findNext(_ sender: Any?) { findBar.findNext() }
    @objc func findPrevious(_ sender: Any?) { findBar.findPrevious() }
    @objc func cancelFind(_ sender: Any?) { findBar.hide() }

    @objc func zoomIn(_ sender: Any?) { setZoom(webController.zoom * 1.1) }
    @objc func zoomOut(_ sender: Any?) { setZoom(webController.zoom / 1.1) }
    @objc func actualSize(_ sender: Any?) { setZoom(1) }

    private func setZoom(_ zoom: Double) {
        webController.setZoom(zoom)
        onPageChanged?(self)
    }

    var zoom: Double { webController.zoom }

    @objc func printPage(_ sender: Any?) {
        guard let window else { return }
        webController.printOperation().runModal(for: window, delegate: nil,
                                                didRun: nil, contextInfo: nil)
    }

    /// The standard Share menu for the current page.
    @objc func sharePage(_ sender: Any?) {
        guard let url = webController.webView.url else { return }
        let picker = NSSharingServicePicker(items: [url])
        let anchor = (sender as? NSView) ?? window?.contentView
        guard let anchor else { return }
        picker.show(relativeTo: .zero, of: anchor, preferredEdge: .minY)
    }

    @objc func copyPageAddress(_ sender: Any?) {
        guard let url = webController.webView.url else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
    }

    /// ⌘L: ask for an address, the way a browser would, without a permanent bar.
    @objc func openLocation(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Go to Address"
        alert.informativeText = "Type or paste an address to open in \(wrapName)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 22))
        field.stringValue = webController.webView.url?.absoluteString ?? ""
        alert.accessoryView = field
        alert.addButton(withTitle: "Go")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn,
                  let url = URLNormalizer.url(from: field.stringValue) else { return }
            self?.webController.load(url)
        }
        // The field has to become first responder *after* the sheet is on screen.
        DispatchQueue.main.async {
            alert.window.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    @objc func toggleBoostsInfo(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Boosts on this page"
        alert.informativeText = webController.boostSummary
            + "\n\nEdit boosts in Wrapybara. Changes apply here without rebuilding this app."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Wrapybara")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertSecondButtonReturn else { return }
            SiteAppDelegate.openWrapybara()
        }
    }

    // MARK: Toolbar

    private enum ToolbarItem {
        static let navigation = NSToolbarItem.Identifier("navigation")
        static let reload = NSToolbarItem.Identifier("reload")
        static let share = NSToolbarItem.Identifier("share")
        static let boosts = NSToolbarItem.Identifier("boosts")
        static let address = NSToolbarItem.Identifier("address")
    }

    private var addressLabel: NSTextField?
    private var navigationControl: NSSegmentedControl?

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: "SiteToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window?.toolbar = toolbar
        // The unified-compact style is what a modern single-window Mac app uses; it
        // keeps the title and the toolbar on one row so the page gets the height.
        window?.toolbarStyle = .unifiedCompact
    }

    @objc private func navigationChanged(_ sender: NSSegmentedControl) {
        sender.selectedSegment == 0 ? webController.goBack() : webController.goForward()
    }

    // MARK: State

    /// Updates the title, the toolbar and Handoff from the page.
    private func refreshFromPage() {
        let webView = webController.webView
        let pageTitle = webView.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Prefer the page's title, the way a browser tab does — it's what makes native
        // tabs useful — but never show an empty title bar.
        window?.title = pageTitle.isEmpty ? wrapName : pageTitle
        window?.representedURL = webView.url

        navigationControl?.setEnabled(webView.canGoBack, forSegment: 0)
        navigationControl?.setEnabled(webView.canGoForward, forSegment: 1)
        addressLabel?.stringValue = webView.url.map { URLNormalizer.displayString(for: $0) } ?? ""

        updateUserActivity()
        onPageChanged?(self)
    }

    /// Publishes the current page as a browsing activity, so Handoff can pick it up on
    /// an iPhone or another Mac. Cheap, and it's the kind of thing that only real apps
    /// bother with.
    private func updateUserActivity() {
        guard behavior.advertisesHandoff else { return }
        guard let url = webController.webView.url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            browsingActivity?.invalidate()
            browsingActivity = nil
            return
        }
        let activity = browsingActivity ?? NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = url
        activity.title = window?.title
        activity.becomeCurrent()
        browsingActivity = activity
    }

    // MARK: Menu validation

    /// Greys out the items that can't do anything right now, so the menu tells the
    /// truth instead of beeping.
    ///
    /// Declared through `NSMenuItemValidation` rather than as an override:
    /// `NSWindowController` doesn't declare `validateMenuItem(_:)`, so `override` here
    /// wouldn't compile.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        switch menuItem.action {
        case #selector(goBack(_:)):
            return webController.webView.canGoBack
        case #selector(goForward(_:)):
            return webController.webView.canGoForward
        case #selector(stopLoading(_:)):
            return webController.webView.isLoading
        case #selector(findNext(_:)), #selector(findPrevious(_:)):
            return findBar.isVisible
        case #selector(sharePage(_:)), #selector(copyPageAddress(_:)), #selector(printPage(_:)):
            return webController.webView.url != nil
        default:
            return true
        }
    }
}

// MARK: - Web controller delegate

extension SiteWindowController: SiteWebControllerDelegate {

    func siteWebControllerDidChangeState(_ controller: SiteWebController) {
        refreshFromPage()
    }

    func siteWebController(_ controller: SiteWebController, openInNewTab url: URL) {
        onOpenInNewTab?(url, self)
    }

    func siteWebController(_ controller: SiteWebController,
                           webViewForPopupWith configuration: WKWebViewConfiguration) -> WKWebView? {
        // Optional-chaining a closure that returns `WKWebView?` gives `WKWebView??`;
        // the `?? nil` flattens "no handler" and "handler declined" into one answer.
        onNeedsPopupWindow?(configuration, self) ?? nil
    }

    func siteWebController(_ controller: SiteWebController, didPickSelector selector: String) {
        // The element picker is armed from Wrapybara's boost editor, whose preview
        // web view is driven by `BoostPreviewController` — a site app has no editor
        // to hand a selection to, so a pick here means the page-side picker was
        // somehow started anyway and there is nothing to do with the result.
    }

    func siteWebController(_ controller: SiteWebController,
                           didPostNotification payload: NotificationBridge.Payload) {
        onNotification?(payload)
    }
}

// MARK: - Window delegate

extension SiteWindowController: NSWindowDelegate {

    func windowWillClose(_ notification: Notification) {
        browsingActivity?.invalidate()
        browsingActivity = nil
    }
}

// MARK: - Toolbar delegate

extension SiteWindowController: NSToolbarDelegate {

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        var items: [NSToolbarItem.Identifier] = [ToolbarItem.navigation, ToolbarItem.reload]
        if behavior.showsAddressBar {
            items.append(contentsOf: [.flexibleSpace, ToolbarItem.address])
        }
        items.append(contentsOf: [.flexibleSpace, ToolbarItem.boosts, ToolbarItem.share])
        return items
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ToolbarItem.navigation, ToolbarItem.reload, ToolbarItem.address,
         ToolbarItem.boosts, ToolbarItem.share, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case ToolbarItem.navigation:
            let control = NSSegmentedControl(images: [
                NSImage(systemSymbolName: "chevron.backward", accessibilityDescription: "Back")
                    ?? NSImage(),
                NSImage(systemSymbolName: "chevron.forward", accessibilityDescription: "Forward")
                    ?? NSImage(),
            ], trackingMode: .momentary, target: self, action: #selector(navigationChanged(_:)))
            control.segmentStyle = .separated
            control.setEnabled(false, forSegment: 0)
            control.setEnabled(false, forSegment: 1)
            navigationControl = control

            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = "Back/Forward"
            item.paletteLabel = "Back/Forward"
            item.isNavigational = true
            return item

        case ToolbarItem.reload:
            return button(identifier, symbol: "arrow.clockwise", label: "Reload",
                          action: #selector(reloadPage(_:)))

        case ToolbarItem.share:
            let item = button(identifier, symbol: "square.and.arrow.up", label: "Share",
                              action: #selector(sharePage(_:)))
            return item

        case ToolbarItem.boosts:
            return button(identifier, symbol: "wand.and.stars", label: "Boosts",
                          action: #selector(toggleBoostsInfo(_:)))

        case ToolbarItem.address:
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.lineBreakMode = .byTruncatingMiddle
            label.alignment = .center
            label.isSelectable = true
            addressLabel = label

            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = label
            item.label = "Address"
            item.paletteLabel = "Address"
            item.visibilityPriority = .low
            return item

        default:
            return nil
        }
    }

    private func button(_ identifier: NSToolbarItem.Identifier, symbol: String, label: String,
                        action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }
}

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
    /// Weak: the container view owns it; the controller only pokes it for a
    /// redraw when the title changes (it draws the title in No chrome).
    private weak var dragStrip: WindowDragStrip?
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
        // A window nobody has moved yet is "at" its centered default; that is what
        // gets remembered until a real frame replaces it.
        lastRegularFrame = window.frame
        lastRegularScreenFrame = window.screen?.frame ?? .zero
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

        // SiteWindow, not NSWindow: ⌘H and a background native tab both read as
        // invisible to WebKit, which hides the page. See `SiteWindow`.
        let window = SiteWindow(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: style, backing: .buffered, defer: false)
        window.minSize = NSSize(width: 400, height: 300)
        if wrap.behavior.chrome.hasTransparentTitleBar {
            window.titlebarAppearsTransparent = true
            // The system renders the title as a text field in the title-bar
            // overlay, which sits above the content view: a click on the name
            // lands there and dies instead of reaching the drag strip. Hide the
            // rendered title — the drag strip draws it. `title` itself stays set
            // for the Dock badge, native tabs, Mission Control and Handoff.
            window.titleVisibility = .hidden
        }
        window.isReleasedWhenClosed = false
        // Native tabs. The identifier has to be shared by every window that may tab
        // together, and `automatic` respects the user's System Settings choice for when
        // to prefer tabs — which is the setting they already made for every other app.
        window.tabbingIdentifier = wrap.bundleIdentifier
        window.tabbingMode = wrap.behavior.allowsNativeTabs ? .automatic : .disallowed
        // `center()` is only the starting point; anything remembered from a previous
        // run is applied by `restore(geometry:)` once the window exists. Not
        // `setFrameAutosaveName`: it remembers one rectangle for the whole app (a
        // shared name can only be claimed by one window at a time), it knows nothing
        // about full screen, and it can't be validated against the screens that exist
        // at relaunch. Placement is restored from `SessionStore` instead — per
        // window, screen-aware, with the full-screen state.
        window.center()
        return window
    }

    // MARK: Content

    private func buildContentView() {
        let webView = webController.webView
        webView.translatesAutoresizingMaskIntoConstraints = false
        findBar.view.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(webView)

        var stripConstraints: [NSLayoutConstraint] = []
        if behavior.chrome.hasTransparentTitleBar {
            // No toolbar and no visible title bar: the web view would swallow
            // every mouse event at the window's top edge and nothing could drag
            // it. The strip reserves that band for dragging. It goes *above* the
            // web view but *below* the find bar, which owns the window's top edge
            // while it's open (the bar hides to zero height, so the strip is the
            // topmost hittable view the rest of the time).
            let strip = WindowDragStrip()
            strip.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(strip)
            dragStrip = strip
            stripConstraints = [
                strip.topAnchor.constraint(equalTo: container.topAnchor),
                strip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                strip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                strip.heightAnchor.constraint(equalToConstant: Self.titleBarHeight),
            ]
        }

        // Last is topmost: the find bar must win its overlap with the drag strip.
        container.addSubview(findBar.view)

        NSLayoutConstraint.activate(stripConstraints + [
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

    /// The system title bar's height for a plain titled window — the strip of page
    /// the drag strip reserves in "No chrome". Measured from the OS rather than
    /// hard-coded, because the metric has moved between macOS releases.
    private static let titleBarHeight: CGFloat = {
        let content = NSRect(x: 0, y: 0, width: 100, height: 100)
        return NSWindow.frameRect(forContentRect: content, styleMask: [.titled]).height
            - content.height
    }()

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

    // MARK: Window placement

    /// The frame to bring this window back at: the last one it had as a regular
    /// window. A window quit in full screen must not come back screen-sized — that
    /// rectangle was chosen by no one — so the regular frame is remembered on its
    /// own and updated only outside full-screen transitions.
    private var lastRegularFrame: NSRect = .zero
    /// The screen `lastRegularFrame` was on, so a relaunch can tell "the display
    /// layout is the same as when this was saved" from "the display this window
    /// lived on is gone".
    private var lastRegularScreenFrame: NSRect = .zero
    /// True from entering or leaving full screen until the transition completes,
    /// so animation frames can't be mistaken for a deliberate resize.
    private var isFullScreenTransition = false

    /// Where this window was when it was last worth remembering.
    var savedGeometry: WindowGeometry {
        WindowGeometry(frame: lastRegularFrame,
                       screenFrame: lastRegularScreenFrame,
                       isFullScreen: window?.styleMask.contains(.fullScreen) ?? false)
    }

    /// Puts the window back where a previous run left it, as close as the screens
    /// that exist now allow. Called before the window is shown, so the restore is
    /// never visible as a jump from the centered default.
    func restore(geometry: WindowGeometry) {
        guard let window, geometry.isUsable else { return }
        let screens = NSScreen.screens.map(WindowGeometry.Screen.init(screen:))
        let frame = geometry.resolvedFrame(on: screens)
        window.setFrame(frame, display: false)
        lastRegularFrame = frame
        // Taken from the screens rather than `window.screen`, which isn't settled
        // for a window that has never been shown.
        lastRegularScreenFrame = (screens.first { $0.frame.intersects(frame) }
            ?? screens.first)?.frame ?? .zero
    }

    /// Puts the window back into full screen, for a window that was quit there.
    ///
    /// Called after the window and its tab group are on screen, and one run-loop
    /// turn later: entering full screen in the same turn as a window's first
    /// appearance races the frame that was just restored.
    func reenterFullScreen() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        DispatchQueue.main.async {
            window.toggleFullScreen(nil)
        }
    }

    /// Records the current frame as the one to bring back, unless the window is in
    /// full screen or animating into or out of it.
    private func rememberRegularFrame() {
        guard let window, !isFullScreenTransition,
              !window.styleMask.contains(.fullScreen) else { return }
        lastRegularFrame = window.frame
        if let screen = window.screen { lastRegularScreenFrame = screen.frame }
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

        // Anchor the menu to whatever asked for it. A toolbar item sends *itself* as
        // the sender (and NSToolbarItem isn't a view), so fall through to its view;
        // a menu item sends the item, in which case the best anchor is the top of
        // the content area — not the zero rect at the content view's bottom-left
        // corner, which is where this used to pop up from.
        var anchor: NSView?
        var rect = NSRect.zero
        if let item = sender as? NSToolbarItem, let view = item.view {
            anchor = view
            rect = view.bounds
        } else if let view = sender as? NSView {
            anchor = view
            rect = view.bounds
        } else if let content = window?.contentView {
            anchor = content
            // A flipped content view puts its origin at the top, so the anchor has
            // to follow the coordinate system — NSView's default isn't flipped, but
            // nothing here gets to assume which one it inherited.
            rect = NSRect(x: 0, y: content.isFlipped ? 0 : content.bounds.maxY,
                          width: 1, height: 1)
        }
        guard let anchor else { return }
        // The edge is read in the anchor view's coordinate system too: `.minY` is
        // visually below the rect in an unflipped view and above it in a flipped
        // one, so follow the same flip the rect does.
        picker.show(relativeTo: rect, of: anchor,
                    preferredEdge: anchor.isFlipped ? .maxY : .minY)
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

    /// Weak: the toolbar retains its items and their views, so these die with
    /// the item instead of being kept alive offscreen after customization.
    private weak var addressLabel: NSTextField?
    private weak var navigationControl: NSSegmentedControl?
    /// Weak: the toolbar owns its items, and a customised-out item should die.
    private weak var reloadToolbarItem: NSToolbarItem?

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
        // In No chrome the drag strip draws the title; nothing else tells it
        // the string changed.
        dragStrip?.needsDisplay = true
        // Deliberately no `representedURL`: that API is for documents, and pointed
        // at a page URL it draws a proxy icon whose drag fails with a "document
        // could not be found" error, and turns the title into a document button
        // that eats the drag gesture the title bar would otherwise offer.

        navigationControl?.setEnabled(webView.canGoBack, forSegment: 0)
        navigationControl?.setEnabled(webView.canGoForward, forSegment: 1)
        addressLabel?.stringValue = webView.url.map { URLNormalizer.displayString(for: $0) } ?? ""

        updateReloadStopItem(isLoading: webView.isLoading)

        updateUserActivity()
        onPageChanged?(self)
    }

    /// The state the reload item is currently showing, so unchanged states skip
    /// the image/action rewrite (a fresh SF Symbol per KVO tick is churn, and
    /// reassigning an identical image can flicker in some toolbar modes).
    private var reloadItemShowsStop = false

    /// Swaps the toolbar's reload button for a stop button while a load is in
    /// flight — the one piece of loading feedback a toolbar owes the user. The
    /// View menu's Stop Loading has always validated correctly; the toolbar had
    /// no state at all.
    private func updateReloadStopItem(isLoading: Bool) {
        guard let item = reloadToolbarItem, isLoading != reloadItemShowsStop else { return }
        reloadItemShowsStop = isLoading
        if isLoading {
            item.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Stop")
            item.action = #selector(stopLoading(_:))
            item.label = "Stop"
            item.toolTip = "Stop loading this page"
        } else {
            item.image = NSImage(systemSymbolName: "arrow.clockwise",
                                 accessibilityDescription: "Reload")
            item.action = #selector(reloadPage(_:))
            item.label = "Reload"
            item.toolTip = "Reload this page"
        }
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
            // A repeat search works with the bar hidden too, the way Safari's ⌘G
            // does — the field's last query is the one that repeats.
            return findBar.isVisible || findBar.canRepeatFind
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

    func windowDidMove(_ notification: Notification) { rememberRegularFrame() }

    func windowDidResize(_ notification: Notification) { rememberRegularFrame() }

    func windowWillEnterFullScreen(_ notification: Notification) {
        // The frame as the window leaves the regular world is the one to bring it
        // back to, captured before the transition can start rewriting it — however
        // the style mask reads by now.
        if let window {
            lastRegularFrame = window.frame
            if let screen = window.screen { lastRegularScreenFrame = screen.frame }
        }
        isFullScreenTransition = true
    }

    func windowWillExitFullScreen(_ notification: Notification) {
        isFullScreenTransition = true
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        isFullScreenTransition = false
        // The exit animation can end after the last `windowDidResize`; capture the
        // restored regular frame now rather than hoping one more event follows.
        rememberRegularFrame()
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
            if flag { navigationControl = control }

            let item = NSToolbarItem(itemIdentifier: identifier)
            item.view = control
            item.label = "Back/Forward"
            item.paletteLabel = "Back/Forward"
            item.isNavigational = true
            return item

        case ToolbarItem.reload:
            let item = button(identifier, symbol: "arrow.clockwise", label: "Reload",
                              action: #selector(reloadPage(_:)))
            // The delegate method also runs for the customization palette's
            // throwaway copy (`flag == false`); capturing that would repoint the
            // swap at an item nobody sees.
            if flag {
                reloadToolbarItem = item
                // The fresh item shows Reload; reset the tracked state so the
                // sync below can't be skipped by an unchanged-from-before flag.
                reloadItemShowsStop = false
                updateReloadStopItem(isLoading: webController.webView.isLoading)
            }
            return item

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
            if flag { addressLabel = label }

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

    /// Builds an *image-based* toolbar item — no `item.view`. That invariant is
    /// what `updateReloadStopItem` relies on: mutating `image`/`action` only
    /// affects the UI for image-based items.
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

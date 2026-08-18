import AppKit
import WebKit

/// The app delegate a generated app runs under.
///
/// Owns the windows, the menu bar, the session, the Dock badge, the notification
/// bridge, and the watcher that lets a boost edited in Wrapybara take effect here
/// without rebuilding this app.
final class SiteAppDelegate: NSObject, NSApplicationDelegate {

    private(set) var configuration: WrapConfiguration
    private var windowControllers: [SiteWindowController] = []
    private let downloads = DownloadCoordinator()
    private lazy var notifications = NotificationBridge(appName: configuration.wrap.name)
    private lazy var watcher = ConfigurationWatcher(directory: AppSupport.runtimeDirectory)
    private var settingsWindow: SiteSettingsWindowController?

    /// The `NSProcessInfo` activity that keeps App Nap away while this app has
    /// something live. See `updateAppNapExemption`.
    private var appNapExemption: NSObjectProtocol?

    private var wrap: Wrap { configuration.wrap }

    init(configuration: WrapConfiguration) {
        self.configuration = configuration
        super.init()
    }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        NSApp.mainMenu = SiteMenuBuilder.mainMenu(appName: wrap.name, wrap: wrap, target: self)
        downloads.completion = .revealInFinder
        downloads.onActiveCountChanged = { [weak self] _ in self?.updateAppNapExemption() }

        notifications.onActivate = { [weak self] pageID in
            self?.handleNotificationClick(pageID: pageID)
        }

        restoreSession()
        watchForConfigurationChanges()
    }

    /// Clicking the Dock icon with no window open reopens one, rather than doing
    /// nothing — the behaviour every Mac app has.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if windowControllers.isEmpty { openWindow(url: nil, asTabOf: nil) }
        else { windowControllers.first?.showWindow(nil) }
        return true
    }

    /// The Dock tile's right-click menu — the actions a person actually reaches for
    /// from the Dock, rather than the macOS defaults alone.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        // Explicit targets: a targetless Dock item would walk the responder chain,
        // and these actions all belong to the app delegate, not any window.
        let newWindowItem = menu.addItem(withTitle: "New Window",
                                         action: #selector(newWindow(_:)), keyEquivalent: "")
        newWindowItem.target = self
        if wrap.behavior.allowsNativeTabs {
            let newTabItem = menu.addItem(withTitle: "New Tab",
                                          action: #selector(newTab(_:)), keyEquivalent: "")
            newTabItem.target = self
        }
        menu.addItem(.separator())
        let homeItem = menu.addItem(withTitle: "Go to Home Page",
                                    action: #selector(goHomeFromDock(_:)), keyEquivalent: "")
        homeItem.target = self
        return menu
    }

    /// Dock-menu "Go to Home Page": the front window navigates home; with no window
    /// open, one is made for it (the same recovery `applicationShouldHandleReopen`
    /// performs for a plain click).
    @objc private func goHomeFromDock(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if let controller = frontWindowController ?? windowControllers.first {
            controller.loadHome()
        } else {
            openWindow(url: nil, asTabOf: nil)
        }
    }

    /// Quit when the last window closes, unless the wrap asked to stay resident.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        !wrap.behavior.staysRunningWithoutWindows
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A download in flight is the one thing worth interrupting a quit for; losing a
        // half-finished file silently is the kind of thing that makes an app feel cheap.
        if downloads.activeCount > 0 {
            let alert = NSAlert()
            alert.messageText = downloads.activeCount == 1
                ? "A download is still in progress"
                : "\(downloads.activeCount) downloads are still in progress"
            alert.informativeText = "Quitting \(wrap.name) now will cancel them."
            alert.addButton(withTitle: "Cancel Downloads and Quit")
            alert.addButton(withTitle: "Don't Quit")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
            downloads.cancelAll()
        }

        if wrap.behavior.confirmsQuitWithOpenTabs, windowControllers.count > 1 {
            let alert = NSAlert()
            alert.messageText = "Quit \(wrap.name)?"
            alert.informativeText = "\(windowControllers.count) windows are open."
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() != .alertFirstButtonReturn { return .terminateCancel }
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        saveSession()
        watcher.stop()
        if let appNapExemption {
            ProcessInfo.processInfo.endActivity(appNapExemption)
            self.appNapExemption = nil
        }
    }

    /// Opt into secure state restoration, silencing the macOS 14+ launch warning. The
    /// session is saved through `SessionStore`, not `NSWindowRestoration`, so this is
    /// free.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Handoff arriving from another device: open the page it was on.
    func application(_ application: NSApplication, continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb,
              let url = userActivity.webpageURL,
              NavigationPolicy.isInApp(url: url, inAppHosts: wrap.inAppHosts) else { return false }
        openWindow(url: url, asTabOf: windowControllers.first)
        return true
    }

    // MARK: Windows

    @objc func newWindow(_ sender: Any?) {
        openWindow(url: nil, asTabOf: nil)
    }

    @objc func newTab(_ sender: Any?) {
        openWindow(url: nil, asTabOf: frontWindowController ?? windowControllers.first)
    }

    private var frontWindowController: SiteWindowController? {
        guard let keyWindow = NSApp.keyWindow else { return nil }
        return windowControllers.first { $0.window === keyWindow }
    }

    /// Creates a window (or a tab of `parent`) and loads `url`, or the home page.
    @discardableResult
    private func openWindow(url: URL?, asTabOf parent: SiteWindowController?) -> SiteWindowController {
        let controller = makeWindowController()
        if let url {
            controller.load(url)
        } else {
            controller.loadHome()
        }
        present(controller, asTabOf: parent)
        return controller
    }

    private func makeWindowController() -> SiteWindowController {
        let controller = SiteWindowController(configuration: configuration, downloads: downloads)
        controller.onOpenInNewTab = { [weak self] url, source in
            self?.openWindow(url: url, asTabOf: source)
        }
        controller.onNeedsPopupWindow = { [weak self] _, source in
            // A popup gets a real window of this app's own making. WebKit's
            // `createWebViewWith` contract wants the *returned* web view to be the one
            // that loads the request, so hand back the new window's web view and let
            // WebKit drive it — calling `load` here would race that.
            guard let self else { return nil }
            let popup = self.makeWindowController()
            self.present(popup, asTabOf: source)
            return popup.webController.webView
        }
        controller.onNotification = { [weak self] payload in
            self?.notifications.post(payload)
        }
        controller.onPageChanged = { [weak self] _ in
            self?.updateBadge()
        }
        windowControllers.append(controller)
        updateAppNapExemption()

        // Drop the controller when its window closes, or every tab ever opened stays
        // alive holding a web content process. The token is captured so the observation
        // unregisters itself — a block observer has no other way to.
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window, queue: .main) { [weak self, weak controller] _ in
                if let token { NotificationCenter.default.removeObserver(token) }
                guard let self, let controller else { return }
                self.windowControllers.removeAll { $0 === controller }
                self.updateBadge()
                self.updateAppNapExemption()
            }
        return controller
    }

    private func present(_ controller: SiteWindowController, asTabOf parent: SiteWindowController?) {
        guard let window = controller.window else { return }
        if let parentWindow = parent?.window, wrap.behavior.allowsNativeTabs, parentWindow != window {
            parentWindow.addTabbedWindow(window, ordered: .above)
        }
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Session

    private func restoreSession() {
        let states = wrap.behavior.restoresSession
            ? SessionStore.load(wrapID: wrap.id)
            : []
        guard !states.isEmpty else {
            openWindow(url: nil, asTabOf: nil)
            return
        }
        var first: SiteWindowController?
        for state in states {
            let controller = makeWindowController()
            controller.restoreOrLoadHome(interactionState: state)
            present(controller, asTabOf: first)
            if first == nil { first = controller }
        }
    }

    private func saveSession() {
        guard wrap.behavior.restoresSession else {
            SessionStore.clear(wrapID: wrap.id)
            return
        }
        SessionStore.save(windowControllers.compactMap(\.interactionState), wrapID: wrap.id)
    }

    // MARK: Live configuration

    private func watchForConfigurationChanges() {
        watcher.onChange = { [weak self] in self?.reloadConfiguration() }
        watcher.start()
    }

    /// Re-reads the configuration and pushes it into every open window, if it changed.
    ///
    /// This is the payoff for keeping the live configuration in a shared directory: you
    /// drag a slider in Wrapybara's boost editor and the app in front of you restyles,
    /// with no rebuild and no relaunch.
    private func reloadConfiguration() {
        guard case let .site(fresh) = LaunchMode.detect(), fresh != configuration else { return }
        configuration = fresh
        for controller in windowControllers {
            controller.apply(fresh)
        }
        settingsWindow?.refresh(with: fresh)
        updateBadge()
    }

    // MARK: Power

    /// Keeps App Nap away while a window is open or a download is in flight.
    ///
    /// A page driven by a long server stream — an agent writing a reply, a live
    /// dashboard — produces no user input and no audio while it works. macOS naps
    /// exactly such apps: not foreground, nothing recently drawn in a visible
    /// window, inaudible, holding no `NSProcessInfo` assertion. Once napped, the
    /// system throttles the app's timers, I/O and CPU — and the WebContent process
    /// is this app's child, so the stream freezes mid-sentence while the server
    /// keeps running. The connection can die while suspended, in which case the
    /// page never catches up even after the app is focused again.
    ///
    /// Taking an activity assertion removes the app — and its process tree — from
    /// App Nap candidacy, which is what Safari does for itself and what any
    /// `WKWebView` host that shows live content has to do for its pages.
    ///
    /// `.userInitiatedAllowingIdleSystemSleep` is the honest strength: the user
    /// opened this app and expects its page to stay current *now*, but the system
    /// may still sleep — with the display asleep nobody is watching, and the page
    /// resumes on wake. Deliberately not `.idleSystemSleepDisabled`, which would
    /// keep the whole machine awake for a chat window.
    ///
    /// Released when the last window closes and no download is running, so a
    /// stay-resident app sitting in the Dock with nothing live still naps.
    private func updateAppNapExemption() {
        let live = !windowControllers.isEmpty || downloads.activeCount > 0
        if live, appNapExemption == nil {
            appNapExemption = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep],
                reason: "Showing a web page the user expects to stay current")
        } else if !live, let appNapExemption {
            ProcessInfo.processInfo.endActivity(appNapExemption)
            self.appNapExemption = nil
        }
    }

    // MARK: Dock badge

    /// Mirrors the unread count a browser tab would show, read out of the page title.
    ///
    /// Browsers badge each tab individually; the Dock shows a single badge, so mirror
    /// the busiest window rather than only the front one — a background window's
    /// "(3) Inbox" still has to reach the Dock. A marker badge with no number ("•")
    /// is shown when no window carries a count, preferring the front window's marker
    /// when more than one kind is showing; if the front window shows no marker, the
    /// first marked window in `windowControllers` order wins the tie-break.
    private func updateBadge() {
        guard wrap.behavior.showsBadgeFromTitle else {
            NSApp.dockTile.badgeLabel = nil
            return
        }
        var bestCount: Int?
        var markerBadge: String?
        for controller in windowControllers {
            guard let title = controller.window?.title else { continue }
            // `count(for:)` can't produce 0 today (a "(0)" title parses to no badge
            // at all), but the guard costs nothing and keeps a zero from ever beating
            // a real count from another window.
            if let count = BadgeFromTitle.count(for: title), count > 0 {
                bestCount = max(bestCount ?? 0, count)
            } else if let badge = BadgeFromTitle.badge(for: title),
                      controller === frontWindowController || markerBadge == nil {
                markerBadge = badge
            }
        }
        if let bestCount {
            NSApp.dockTile.badgeLabel = "\(bestCount)"
        } else if let markerBadge {
            NSApp.dockTile.badgeLabel = markerBadge
        } else {
            NSApp.dockTile.badgeLabel = nil
        }
    }

    // MARK: Notifications

    /// A forwarded notification was clicked: bring the app forward and let the page's
    /// own `onclick` run, which is what actually navigates to the message.
    private func handleNotificationClick(pageID: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let controller = frontWindowController ?? windowControllers.first
        controller?.showWindow(nil)
        guard pageID != 0 else { return }
        controller?.webController.webView.evaluateJavaScript(
            "window.__wrapybara && window.__wrapybara.notificationClicked(\(pageID))",
            completionHandler: nil)
    }

    // MARK: Menu actions

    @objc func showAbout(_ sender: Any?) {
        let version = Bundle.main.shortVersionString
        let generatedBy = (Bundle.main.object(
            forInfoDictionaryKey: InfoPlistBuilder.Key.generatedBy) as? String) ?? "Wrapybara"
        let alert = NSAlert()
        alert.messageText = wrap.name
        alert.informativeText = """
        \(wrap.homeURL.absoluteString)

        A native macOS wrapper built with \(generatedBy) (runtime \(version)).
        Web content belongs to its owners.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Visit Site")
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(wrap.homeURL)
        }
    }

    @objc func showSettings(_ sender: Any?) {
        if settingsWindow == nil {
            settingsWindow = SiteSettingsWindowController(configuration: configuration)
        }
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc func openWrapybaraForThisWrap(_ sender: Any?) {
        Self.openWrapybara()
    }

    @objc func showHelp(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/L-K-M/Wrapybara#readme") else { return }
        NSWorkspace.shared.open(url)
    }

    /// Brings Wrapybara forward, or tells the user it isn't installed.
    ///
    /// Looked up by bundle identifier rather than by path: a generated app deliberately
    /// stores no path back to the builder, precisely so that moving or deleting
    /// Wrapybara can't break it.
    static func openWrapybara() {
        let identifier = "com.wrapybara.Wrapybara"
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Wrapybara isn't installed"
        alert.informativeText = """
        This app keeps working on its own, but editing its boosts needs Wrapybara.
        """
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Get Wrapybara")
        if alert.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/L-K-M/Wrapybara/releases/latest") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Helpers

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

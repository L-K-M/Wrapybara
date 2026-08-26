import Foundation

/// How a generated app behaves, as opposed to how the pages inside it look
/// (`Boost`). Everything here is decided once per wrap and read by the runtime at
/// launch.
struct WrapBehavior: Codable, Equatable {

    /// How much window furniture the site app shows.
    enum Chrome: String, Codable, CaseIterable, Identifiable {
        /// A unified toolbar with back/forward, reload, share and the boost button.
        /// The default, and the one that looks like a Mac app.
        case toolbar
        /// Title bar only — no toolbar. For sites with their own top bar.
        case titleBarOnly
        /// Full-size content under a transparent title bar. Traffic lights float
        /// over the page.
        case none

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .toolbar: return "Toolbar"
            case .titleBarOnly: return "Title bar only"
            case .none: return "No chrome"
            }
        }

        var showsToolbar: Bool { self == .toolbar }
        var hasTransparentTitleBar: Bool { self == Chrome.none }
    }

    /// What happens when the page navigates somewhere the wrap doesn't own.
    enum ExternalLinkPolicy: String, Codable, CaseIterable, Identifiable {
        /// Hand off to the user's default browser. The default: a site app that
        /// silently becomes a general-purpose browser is the thing that makes these
        /// wrappers feel wrong.
        case openInDefaultBrowser
        /// Keep everything inside the app, however far it wanders.
        case keepInApp
        /// Open it in a new tab of this app, but only for `http(s)`.
        case openInNewTab

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .openInDefaultBrowser: return "Open in default browser"
            case .keepInApp: return "Keep in this app"
            case .openInNewTab: return "Open in a new tab"
            }
        }
    }

    /// Which `User-Agent` the web view claims.
    ///
    /// Sites sniff. A WKWebView's default UA already says Safari, but it also says
    /// the app's name, which some sites don't recognise; `.safari` sends a clean
    /// desktop-Safari string instead.
    enum UserAgentMode: String, Codable, CaseIterable, Identifiable {
        case standard, safari, custom

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .standard: return "WebKit default"
            case .safari: return "Desktop Safari"
            case .custom: return "Custom…"
            }
        }
    }

    // MARK: Window

    var chrome: Chrome
    /// Show the current URL in the toolbar. Off by default — a site app doesn't
    /// need an address bar, and ⌘L still works without one.
    var showsAddressBar: Bool
    var allowsNativeTabs: Bool
    /// Reopen at the page (and scroll position) the window was on when it closed.
    var restoresSession: Bool
    var initialWindowWidth: Double
    var initialWindowHeight: Double
    /// `1.0` = 100%. Persisted separately from the boost theme's `fontScale`
    /// because this is the app's zoom, and ⌘+/⌘− writes back to it.
    var pageZoom: Double

    // MARK: Navigation

    var externalLinks: ExternalLinkPolicy
    /// Extra hosts (beyond the home URL's) that count as "inside" the wrap —
    /// an identity provider, a CDN-hosted editor, a docs subdomain on another
    /// registrable domain. Subdomains of each entry count too.
    var additionalInAppHosts: [String]
    var userAgentMode: UserAgentMode
    var customUserAgent: String

    // MARK: Integration

    /// Pull a number out of the page title (`(3) Inbox`) and put it on the Dock
    /// icon. `BadgeFromTitle` does the parsing.
    var showsBadgeFromTitle: Bool
    /// Bridge the page's `Notification` API to real macOS notifications.
    /// WKWebView has no notification support of its own, so this installs a shim —
    /// see `NotificationBridge`.
    var forwardsWebNotifications: Bool
    /// Publish the current page as an `NSUserActivity` so it can be picked up by
    /// Handoff on another device.
    var advertisesHandoff: Bool
    /// Ask before quitting while more than one tab is open.
    var confirmsQuitWithOpenTabs: Bool
    /// Keep the app running (in the Dock, no window) after its last window closes,
    /// instead of quitting. Off by default: a site app that won't die is annoying.
    var staysRunningWithoutWindows: Bool

    // MARK: Content

    /// Allows the Web Inspector for this app's pages: Inspect Element in the
    /// page's context menu, Show Web Inspector (⌥⌘I) in its View menu, and remote
    /// attach from Safari's Develop menu. Off by default — a shipped site app has
    /// no business exposing its page's guts.
    var isWebInspectorEnabled: Bool

    init(chrome: Chrome = .toolbar,
         showsAddressBar: Bool = false,
         allowsNativeTabs: Bool = true,
         restoresSession: Bool = true,
         initialWindowWidth: Double = 1200,
         initialWindowHeight: Double = 800,
         pageZoom: Double = 1,
         externalLinks: ExternalLinkPolicy = .openInDefaultBrowser,
         additionalInAppHosts: [String] = [],
         userAgentMode: UserAgentMode = .standard,
         customUserAgent: String = "",
         showsBadgeFromTitle: Bool = true,
         forwardsWebNotifications: Bool = false,
         advertisesHandoff: Bool = true,
         confirmsQuitWithOpenTabs: Bool = false,
         staysRunningWithoutWindows: Bool = false,
         isWebInspectorEnabled: Bool = false) {
        self.chrome = chrome
        self.showsAddressBar = showsAddressBar
        self.allowsNativeTabs = allowsNativeTabs
        self.restoresSession = restoresSession
        self.initialWindowWidth = initialWindowWidth
        self.initialWindowHeight = initialWindowHeight
        self.pageZoom = pageZoom
        self.externalLinks = externalLinks
        self.additionalInAppHosts = additionalInAppHosts
        self.userAgentMode = userAgentMode
        self.customUserAgent = customUserAgent
        self.showsBadgeFromTitle = showsBadgeFromTitle
        self.forwardsWebNotifications = forwardsWebNotifications
        self.advertisesHandoff = advertisesHandoff
        self.confirmsQuitWithOpenTabs = confirmsQuitWithOpenTabs
        self.staysRunningWithoutWindows = staysRunningWithoutWindows
        self.isWebInspectorEnabled = isWebInspectorEnabled
    }

    static let `default` = WrapBehavior()

    /// The `User-Agent` string to set on the web view, or `nil` to leave WebKit's
    /// own alone.
    var resolvedUserAgent: String? {
        switch userAgentMode {
        case .standard:
            return nil
        case .safari:
            return Self.desktopSafariUserAgent
        case .custom:
            let trimmed = customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// A plain desktop-Safari `User-Agent`.
    ///
    /// Deliberately a fixed string rather than one assembled from the running OS
    /// version: the point is to look like something sites already allow-list, and a
    /// UA naming an OS release that a site's sniffing predates is worse than a
    /// slightly stale one. Bump it when a site starts complaining.
    static let desktopSafariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/17.6 Safari/605.1.15"

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case chrome, showsAddressBar, allowsNativeTabs, restoresSession
        case initialWindowWidth, initialWindowHeight, pageZoom
        case externalLinks, additionalInAppHosts, userAgentMode, customUserAgent
        case showsBadgeFromTitle, forwardsWebNotifications, advertisesHandoff
        case confirmsQuitWithOpenTabs, staysRunningWithoutWindows
        case isWebInspectorEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.chrome = c.value(.chrome, or: Chrome.toolbar)
        self.showsAddressBar = c.value(.showsAddressBar, or: false)
        self.allowsNativeTabs = c.value(.allowsNativeTabs, or: true)
        self.restoresSession = c.value(.restoresSession, or: true)
        self.initialWindowWidth = c.value(.initialWindowWidth, or: 1200.0)
        self.initialWindowHeight = c.value(.initialWindowHeight, or: 800.0)
        self.pageZoom = c.value(.pageZoom, or: 1.0)
        self.externalLinks = c.value(.externalLinks, or: ExternalLinkPolicy.openInDefaultBrowser)
        self.additionalInAppHosts = c.value(.additionalInAppHosts, or: [String]())
        self.userAgentMode = c.value(.userAgentMode, or: UserAgentMode.standard)
        self.customUserAgent = c.value(.customUserAgent, or: "")
        self.showsBadgeFromTitle = c.value(.showsBadgeFromTitle, or: true)
        self.forwardsWebNotifications = c.value(.forwardsWebNotifications, or: false)
        self.advertisesHandoff = c.value(.advertisesHandoff, or: true)
        self.confirmsQuitWithOpenTabs = c.value(.confirmsQuitWithOpenTabs, or: false)
        self.staysRunningWithoutWindows = c.value(.staysRunningWithoutWindows, or: false)
        self.isWebInspectorEnabled = c.value(.isWebInspectorEnabled, or: false)
    }
}

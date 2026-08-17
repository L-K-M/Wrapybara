import Foundation

/// Decides what a site app does with a navigation.
///
/// This is the single rule that separates a site app from a browser: a wrap for
/// your mail should stay on your mail, and a link to a news article should land in
/// the browser you actually chose. Getting it wrong in either direction is the most
/// visible thing a wrapper can do, so the whole decision is pure and table-tested.
enum NavigationPolicy {

    enum Decision: Equatable {
        /// Load it in the web view that asked.
        case allow
        /// Load it in a new tab (or window) of this app.
        case openInNewTab
        /// Hand it to the user's default browser and cancel the navigation.
        case openExternally
        /// Refuse it outright.
        case block
    }

    /// Schemes the app itself can load.
    static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data"]

    /// Schemes that belong to another app (`mailto:`, `tel:`, `zoommtg:`, …). These
    /// always leave, whatever the external-link policy says — a web view can't load
    /// them, and swallowing them would just make the link look broken.
    static func isHandOffScheme(_ scheme: String) -> Bool {
        !webSchemes.contains(scheme.lowercased()) && scheme.lowercased() != "file"
    }

    /// The decision for a top-level navigation.
    ///
    /// - Parameters:
    ///   - url: where the page wants to go.
    ///   - inAppHosts: hosts that count as inside the wrap (`Wrap.inAppHosts`).
    ///   - policy: what the user chose for links that leave the wrap.
    ///   - isUserInitiated: true when a click or a keyboard action caused it, false
    ///     for a script- or redirect-driven navigation. Redirects are never sent to
    ///     the browser: a login flow that bounces through an identity provider and
    ///     back would otherwise dump the user into Safari mid-handshake.
    ///   - targetsNewWindow: true when the page asked for a new window/tab
    ///     (`target="_blank"`, `window.open`).
    static func decide(for url: URL,
                       inAppHosts: [String],
                       policy: WrapBehavior.ExternalLinkPolicy,
                       isUserInitiated: Bool,
                       targetsNewWindow: Bool) -> Decision {
        let scheme = (url.scheme ?? "").lowercased()

        // `file:` URLs never come from a remote page legitimately.
        if scheme == "file" { return .block }
        if scheme.isEmpty { return .allow }         // relative/fragment navigation
        if isHandOffScheme(scheme) { return .openExternally }

        // `about:`, `blob:` and `data:` have no host to compare and are how WebKit
        // does blank pages, generated downloads and inline previews.
        if scheme == "about" || scheme == "blob" || scheme == "data" { return .allow }

        if isInApp(url: url, inAppHosts: inAppHosts) {
            // Inside the wrap: a `target="_blank"` still deserves a real tab rather
            // than replacing what the user was looking at.
            return targetsNewWindow ? .openInNewTab : .allow
        }

        // Outside the wrap.
        guard isUserInitiated else { return .allow }

        switch policy {
        case .keepInApp:
            return targetsNewWindow ? .openInNewTab : .allow
        case .openInNewTab:
            return .openInNewTab
        case .openInDefaultBrowser:
            return .openExternally
        }
    }

    /// Whether `url`'s host is one of the wrap's hosts, or a subdomain of one.
    static func isInApp(url: URL, inAppHosts: [String]) -> Bool {
        isInApp(host: url.host ?? "", inAppHosts: inAppHosts)
    }

    /// The host-only form, for callers that have a host rather than a URL — a
    /// `WKSecurityOrigin` from a permission request, say.
    static func isInApp(host rawHost: String, inAppHosts: [String]) -> Bool {
        let host = rawHost.lowercased()
        guard !host.isEmpty else { return false }
        for candidate in inAppHosts {
            let wanted = BoostMatcher.normalizedHost(candidate)
            guard !wanted.isEmpty else { continue }
            if host == wanted || host.hasSuffix("." + wanted) { return true }
        }
        return false
    }
}

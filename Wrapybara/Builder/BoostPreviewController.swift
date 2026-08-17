import AppKit
import WebKit

/// Drives the boost editor's live preview.
///
/// Reuses `SiteWebController` rather than growing a second web-view implementation: it
/// already knows how to build a boost's user scripts, re-apply a stylesheet to a page
/// that's already loaded, and run the element picker. Feeding it a one-boost
/// configuration means the preview is applying *exactly* what the built app will.
///
/// Two things are overridden for the preview: links stay in the app (a preview that
/// launches Safari when you click something is useless), and the wrap's page zoom is
/// left alone so the preview isn't scaled twice.
final class BoostPreviewController: NSObject {

    let webController: SiteWebController
    private let downloads = DownloadCoordinator()
    private var pickCompletion: ((String) -> Void)?

    init(wrap: Wrap, boost: Boost) {
        self.webController = SiteWebController(
            configuration: Self.previewConfiguration(wrap: wrap, boost: boost),
            downloads: downloads)
        super.init()
        webController.delegate = self
        // The preview never downloads anything the user asked for; if a click produces
        // one, quietly put it where downloads go rather than surprising them.
        downloads.completion = .doNothing
    }

    var view: NSView { webController.webView }

    /// The last pair actually applied, so unrelated SwiftUI renders can be skipped.
    private var lastAppliedWrap: Wrap?
    private var lastAppliedBoost: Boost?

    // MARK: Contents

    /// A configuration carrying only the boost being edited.
    ///
    /// Deliberately *not* the wrap's whole resolved boost list. The preview answers
    /// "what does this boost do?", and showing it stacked under five others would make
    /// a subtle change impossible to see.
    static func previewConfiguration(wrap: Wrap, boost: Boost) -> WrapConfiguration {
        var previewWrap = wrap
        previewWrap.behavior.externalLinks = .keepInApp
        previewWrap.behavior.pageZoom = 1
        previewWrap.behavior.forwardsWebNotifications = false
        previewWrap.behavior.showsBadgeFromTitle = false
        previewWrap.behavior.advertisesHandoff = false
        // The preview is a development surface, so let the inspector work in it.
        previewWrap.behavior.isWebInspectorEnabled = true
        return WrapConfiguration.resolved(previewWrap, boosts: [boost],
                                          generatedBy: "preview")
    }

    func loadHome() { webController.loadHome() }
    func reload() { webController.reload() }

    /// Re-applies an edited boost without reloading the page, so the scroll position and
    /// any signed-in state survive a slider drag.
    ///
    /// The preview's `updateNSView` runs on *every* SwiftUI render — name-field
    /// typing, sheet toggles, unrelated selection changes included — and each apply
    /// rebuilds the injector, clears the matcher cache, reinstalls user scripts and
    /// evaluates JavaScript against the page. Nothing the preview shows changed in
    /// those cases, so skip them; `Wrap` and `Boost` are both `Equatable`, which is
    /// precisely the "did anything the preview applies change?" question.
    func apply(wrap: Wrap, boost: Boost) {
        if let lastAppliedWrap, let lastAppliedBoost,
           lastAppliedWrap == wrap, lastAppliedBoost == boost {
            return
        }
        lastAppliedWrap = wrap
        lastAppliedBoost = boost
        webController.apply(Self.previewConfiguration(wrap: wrap, boost: boost))
    }

    var currentURL: URL? { webController.webView.url }

    // MARK: Picking

    /// Starts the element picker; `completion` gets the selector, or `""` if cancelled.
    func beginPicking(completion: @escaping (String) -> Void) {
        pickCompletion = completion
        webController.beginPickingElement()
    }
}

// MARK: - SiteWebControllerDelegate

extension BoostPreviewController: SiteWebControllerDelegate {

    func siteWebControllerDidChangeState(_ controller: SiteWebController) {}

    /// A `target="_blank"` in the preview loads in place rather than spawning a window.
    func siteWebController(_ controller: SiteWebController, openInNewTab url: URL) {
        controller.load(url)
    }

    func siteWebController(_ controller: SiteWebController,
                           webViewForPopupWith configuration: WKWebViewConfiguration) -> WKWebView? {
        nil
    }

    func siteWebController(_ controller: SiteWebController, didPickSelector selector: String) {
        let completion = pickCompletion
        pickCompletion = nil
        completion?(selector)
    }

    func siteWebController(_ controller: SiteWebController,
                           didPostNotification payload: NotificationBridge.Payload) {
        // The preview doesn't post system notifications; a boost under test shouldn't be
        // able to fill Notification Center while it's being written.
    }
}

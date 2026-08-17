import AppKit
import SwiftUI
import WebKit

/// The live preview beside the boost editor: the real site, with the boost applied.
struct BoostPreviewView: View {

    @ObservedObject var model: LibraryModel
    let wrap: Wrap
    let boost: Boost

    var body: some View {
        VStack(spacing: 0) {
            PreviewWebView(model: model, wrap: wrap, boost: boost)
            Divider()
            statusBar
        }
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Button {
                model.previewController?.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Reload the preview")

            Button {
                model.previewController?.loadHome()
            } label: {
                Image(systemName: "house")
            }
            .buttonStyle(.borderless)
            .help("Back to the home page")

            Text(model.previewController?.currentURL
                 .map { URLNormalizer.displayString(for: $0, maxLength: 52) }
                 ?? URLNormalizer.displayString(for: wrap.homeURL, maxLength: 52))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Spacer()

            if model.isPickingElement {
                Label("Click an element · ↑ widen · Esc cancel", systemImage: "scope")
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else {
                Button("Pick an Element") {
                    model.beginPickingElement(for: boost, in: wrap)
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

// MARK: - Web view bridge

/// Hosts the preview's `WKWebView`.
///
/// The controller is kept on `LibraryModel` rather than in this view's coordinator so
/// the Zap button — which lives in a different subtree — can reach it. A SwiftUI view is
/// recreated on any state change; the web view, its session, and the page's scroll
/// position must not be.
private struct PreviewWebView: NSViewRepresentable {

    @ObservedObject var model: LibraryModel
    let wrap: Wrap
    let boost: Boost

    /// Owns the controller for as long as the representable exists.
    ///
    /// The model's reference is `weak` — it's a convenience for the Zap button, not
    /// ownership — so something has to hold the controller strongly, and the coordinator's
    /// lifetime is exactly the preview's.
    final class Coordinator {
        var controller: BoostPreviewController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let controller = BoostPreviewController(wrap: wrap, boost: boost)
        context.coordinator.controller = controller
        model.previewController = controller
        controller.loadHome()
        return controller.view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Re-apply on every edit. `SiteWebController.apply` re-evaluates the stylesheet
        // against the live page, so this is a restyle rather than a reload — the scroll
        // position and any signed-in state stay put.
        model.previewController?.apply(wrap: wrap, boost: boost)
    }
}

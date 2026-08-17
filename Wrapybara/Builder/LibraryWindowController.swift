import AppKit
import SwiftUI

/// Hosts Wrapybara's one window, and bridges the menu bar to the SwiftUI view's state.
///
/// The menu can't reach into a SwiftUI hierarchy, so the actions it needs live on
/// `LibraryModel` and this controller forwards to them.
final class LibraryWindowController: NSWindowController {

    private let model: LibraryModel

    init(store: WrapStore, exporter: WrapExporter, preferences: Preferences) {
        let model = LibraryModel(store: store, exporter: exporter, preferences: preferences)
        self.model = model

        let hosting = NSHostingController(rootView: LibraryView(model: model)
            .environmentObject(store)
            .environmentObject(preferences))
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.title = "Wrapybara"
        window.titleVisibility = .visible
        window.setContentSize(NSSize(width: 1040, height: 680))
        window.minSize = NSSize(width: 860, height: 540)
        window.isReleasedWhenClosed = false
        window.center()
        window.setFrameAutosaveName("LibraryWindow")
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("LibraryWindowController is created in code, not from a nib")
    }

    // MARK: Menu bridge

    func beginNewWrap() { model.sheet = .newWrap }

    func showSettings() { model.sheet = .settings }

    func buildSelectedWrap() {
        guard let wrap = model.selectedWrap else { return }
        model.build(wrap)
    }

    func refreshStaleRuntimes() { model.refreshStaleRuntimes() }

    /// Imports `.wrapyboost` files dropped on the Dock icon or picked from a panel.
    func importBoosts(from urls: [URL]) {
        model.importBoosts(from: urls)
    }
}

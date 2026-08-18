import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

/// View state and actions for the library window.
///
/// The views read and write this; it talks to `WrapStore` and `WrapExporter`. Keeping
/// the two apart means a SwiftUI view never has to know that saving a boost also
/// republishes a configuration file that a running app is watching.
final class LibraryModel: ObservableObject {

    let store: WrapStore
    let exporter: WrapExporter
    let preferences: Preferences

    @Published var selectedWrapID: UUID?
    @Published var selectedBoostID: UUID?

    /// Which sheet, if any, is up.
    @Published var sheet: Sheet?
    /// A message to show in an alert. Set from any failure path.
    @Published var alert: AlertContent?
    /// True while a build is running, to disable the button and show progress.
    @Published var isBuilding = false
    /// True while the site is being crawled for an icon.
    @Published var isFetchingIcon = false
    /// True while the Zap picker is armed in the preview.
    @Published var isPickingElement = false

    /// The boost editor's live preview, when one is on screen.
    ///
    /// Held here rather than in the preview view's coordinator because the Zap button
    /// lives in a different part of the view tree and has to reach it — and because a
    /// SwiftUI view is recreated on every state change while a web view, its session and
    /// its scroll position must not be. `weak`, so closing the editor lets the web
    /// content process go.
    weak var previewController: BoostPreviewController?

    enum Sheet: Identifiable {
        case newWrap
        case settings

        var id: String {
            switch self {
            case .newWrap: return "newWrap"
            case .settings: return "settings"
            }
        }
    }

    struct AlertContent: Identifiable {
        let id = UUID()
        var title: String
        var message: String
        var isError: Bool
    }

    /// Republishes the store's changes as this model's own.
    ///
    /// The views read the library through `model`, so without this a boost edit would
    /// update `library.json` and every running site app while the editor that made the
    /// edit sat there showing stale values.
    private var storeObservation: AnyCancellable?

    init(store: WrapStore, exporter: WrapExporter, preferences: Preferences) {
        self.store = store
        self.exporter = exporter
        self.preferences = preferences
        self.selectedWrapID = store.library.wraps.first?.id
        self.storeObservation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }

    // MARK: Derived

    var wraps: [Wrap] { store.library.wraps }

    var selectedWrap: Wrap? {
        guard let selectedWrapID else { return nil }
        return store.library.wrap(id: selectedWrapID)
    }

    /// The boost being edited, looked up in the selected wrap and then in the shared
    /// shelf — the editor treats both the same.
    var selectedBoost: Boost? {
        guard let selectedBoostID else { return nil }
        if let boost = selectedWrap?.boosts.first(where: { $0.id == selectedBoostID }) {
            return boost
        }
        return store.library.sharedBoosts.first { $0.id == selectedBoostID }
    }

    var staleWrapCount: Int {
        let version = Bundle.main.shortVersionString
        return wraps.filter { $0.hasStaleRuntime(currentVersion: version) }.count
    }

    // MARK: Wraps

    /// Creates a wrap for `input`, fetches its icon, and selects it.
    ///
    /// The icon fetch is deliberately *not* awaited before the wrap appears: a slow
    /// site shouldn't hold up the UI, and the monogram is a perfectly good placeholder
    /// until the artwork lands.
    @MainActor
    func createWrap(from input: String, name: String?) {
        guard let url = URLNormalizer.url(from: input) else {
            alert = AlertContent(title: "That doesn't look like a web address",
                                 message: "Try something like claude.ai or https://app.example.com.",
                                 isError: true)
            return
        }
        let wrap = store.makeWrap(for: url, name: name)
        store.add(wrap)
        selectedWrapID = wrap.id
        sheet = nil
        Task { await fetchIcon(for: wrap.id, applySuggestedName: name == nil) }
    }

    func update(_ wrap: Wrap) {
        // A monogram is drawn from the wrap's name and plate rather than fetched,
        // but the fetch path still saves it as a PNG — so an edit that changes
        // either input (a rename, a plate restyle) would otherwise leave the old
        // monogram on disk, and the library and any build would keep showing it.
        // Redrawing here is what keeps "the monogram is just the current inputs,
        // rendered" true.
        let previous = store.library.wrap(id: wrap.id)
        if wrap.icon.origin == .monogram,
           previous?.name != wrap.name || previous?.icon != wrap.icon {
            try? exporter.saveIcon(IconComposer.monogram(WrapIcon.initials(for: wrap.name),
                                                         plate: IconPlate.resolved(for: wrap.icon)),
                                   for: wrap)
        }
        store.update(wrap)
    }

    func deleteWrap(_ wrap: Wrap) {
        let hasApp = wrap.installedAppURL != nil
        let alert = NSAlert()
        alert.messageText = "Remove “\(wrap.name)” from the library?"
        alert.informativeText = hasApp
            ? "The app it built stays in place. Use “Move App to Trash” first if you want it gone."
            : "This can't be undone."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let index = wraps.firstIndex { $0.id == wrap.id }
        store.remove(wrapID: wrap.id)
        // Keep something selected: land on the neighbour rather than an empty pane.
        if let index {
            selectedWrapID = wraps.indices.contains(index) ? wraps[index].id : wraps.last?.id
        } else {
            selectedWrapID = wraps.first?.id
        }
    }

    func trashApp(for wrap: Wrap) {
        do {
            try exporter.moveAppToTrash(for: wrap)
        } catch {
            alert = AlertContent(title: "Couldn't move the app to the Trash",
                                 message: error.localizedDescription, isError: true)
        }
    }

    // MARK: Building

    func build(_ wrap: Wrap) {
        guard !isBuilding else { return }
        isBuilding = true
        // The work is main-actor bound (it mutates the store and the published flags),
        // so this `Task` does not move it off the main thread — it only defers it past
        // this run-loop turn so the progress state renders before the build blocks.
        // Writing a few megabytes and running `codesign` over one small bundle is
        // sub-second; buying a background hop would mean making the exporter and store
        // thread-safe, which is a real cost for a hitch nobody sees.
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBuilding = false }
            do {
                let outcome = try self.exporter.build(wrap)
                self.exporter.performPostBuildActions(for: outcome.appURL)
                self.alert = AlertContent(
                    title: "Built “\(outcome.wrap.name)”",
                    message: outcome.appURL.path,
                    isError: false)
            } catch {
                self.alert = AlertContent(title: "Couldn't build “\(wrap.name)”",
                                          message: Self.describe(error), isError: true)
            }
        }
    }

    func refreshStaleRuntimes() {
        guard !isBuilding else { return }
        isBuilding = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.isBuilding = false }
            let result = self.exporter.refreshStaleRuntimes()
            if result.updated.isEmpty, result.failures.isEmpty {
                self.alert = AlertContent(title: "Everything is up to date",
                                          message: "No wrap needed rebuilding.", isError: false)
                return
            }
            var message = result.updated.isEmpty ? "" :
                "Rebuilt: " + result.updated.map(\.name).joined(separator: ", ")
            if !result.failures.isEmpty {
                if !message.isEmpty { message += "\n\n" }
                message += result.failures
                    .map { "\($0.wrap.name): \(Self.describe($0.error))" }
                    .joined(separator: "\n")
            }
            self.alert = AlertContent(title: "Rebuilt \(result.updated.count) wrap(s)",
                                      message: message, isError: !result.failures.isEmpty)
        }
    }

    /// Includes a recovery suggestion when the error carries one — the missing-Command-
    /// Line-Tools case is useless without its "run xcode-select --install".
    static func describe(_ error: Error) -> String {
        let localized = error.localizedDescription
        guard let suggestion = (error as? LocalizedError)?.recoverySuggestion,
              !suggestion.isEmpty else { return localized }
        return "\(localized)\n\n\(suggestion)"
    }

    // MARK: Icons

    /// Crawls the wrap's site for artwork and saves what it finds.
    ///
    /// `@MainActor` so that execution resumes on the main thread after the network
    /// `await` — everything it touches afterwards is `@Published` state and the store.
    @MainActor
    func fetchIcon(for wrapID: UUID, applySuggestedName: Bool = false) async {
        guard let wrap = store.library.wrap(id: wrapID) else { return }
        isFetchingIcon = true
        defer { isFetchingIcon = false }

        let fetcher = SiteIconFetcher()
        let outcome = await fetcher.icon(for: wrap.homeURL,
                                        fallbackName: wrap.name,
                                        style: preferences.iconStyle,
                                        plate: wrap.icon.plate)

        guard var current = store.library.wrap(id: wrapID) else { return }
        do {
            try exporter.saveIcon(outcome.icon, for: current)
        } catch {
            alert = AlertContent(title: "Couldn't save the icon",
                                 message: error.localizedDescription, isError: true)
            return
        }
        // The raw artwork, so a later plate restyle can recompose without
        // re-fetching. A courtesy copy: the icon is saved, so a failure here
        // only means the recompose path asks for the artwork again.
        if let artwork = outcome.artwork {
            try? exporter.saveArtwork(artwork, for: current)
        }
        current.icon = WrapIcon(
            origin: outcome.isFallback ? .monogram : .fetchedFromSite,
            sourceURL: outcome.sourceURL,
            tintHex: outcome.themeColorHex.flatMap { BoostCSSGenerator.sanitizedColor($0) }
                ?? WrapIcon.tintHex(for: current.name),
            monogram: WrapIcon.initials(for: current.name),
            // A deliberately chosen plate survives re-fetching — it's why the
            // fetch composed with it. `current`'s, not `wrap`'s: the freshest.
            plate: current.icon.plate)
        // Only take the site's own name when the user didn't type one.
        if applySuggestedName, let suggested = outcome.suggestedName,
           !suggested.isEmpty, current.name != suggested {
            let unique = AppNameSanitizer.uniqueFileName(
                for: suggested,
                avoiding: store.library.usedAppFileNames.subtracting([current.appFileName]))
            current.name = unique
        }
        store.update(current)
    }

    /// Replaces the wrap's artwork with an image file the user chose.
    func chooseIconFile(for wrap: Wrap) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose artwork for \(wrap.name)"
        guard panel.runModal() == .OK, let url = panel.url,
              let image = NSImage(contentsOf: url), image.isValid else { return }

        let composed = IconComposer.compose(artwork: image,
                                            style: preferences.iconStyle,
                                            plate: IconPlate.resolved(for: wrap.icon))
        do {
            try exporter.saveIcon(composed, for: wrap)
            // As with a fetch: keep the raw artwork for future plate restyles.
            try? exporter.saveArtwork(image, for: wrap)
            var updated = wrap
            updated.icon.origin = .pickedFile
            updated.icon.sourceURL = url
            store.update(updated)
        } catch {
            alert = AlertContent(title: "Couldn't save the icon",
                                 message: error.localizedDescription, isError: true)
        }
    }

    /// Restyles the plate behind the wrap's artwork and redraws the icon.
    ///
    /// `nil` restores *automatic*: a gradient in the wrap's tint, tracking the
    /// site's `theme-color` on the next fetch. The choice is stored even when the
    /// artwork to draw it behind isn't on disk — a wrap whose icon predates
    /// artwork retention picks the new plate up on its next fetch or file pick.
    func updateIconPlate(_ plate: IconPlate?, for wrap: Wrap) {
        var updated = wrap
        updated.icon.plate = plate
        let resolved = IconPlate.resolved(for: updated.icon)

        switch updated.icon.origin {
        case .monogram:
            // A monogram is drawn, never fetched, so there's always something to
            // redraw — no artwork needed.
            do {
                try exporter.saveIcon(IconComposer.monogram(WrapIcon.initials(for: updated.name),
                                                            plate: resolved),
                                      for: updated)
            } catch {
                alert = AlertContent(title: "Couldn't save the icon",
                                     message: error.localizedDescription, isError: true)
            }
        case .pickedFile, .fetchedFromSite:
            if let artwork = artworkForRecomposing(updated) {
                do {
                    try exporter.saveIcon(IconComposer.compose(artwork: artwork,
                                                               style: preferences.iconStyle,
                                                               plate: resolved),
                                          for: updated)
                } catch {
                    alert = AlertContent(title: "Couldn't save the icon",
                                         message: error.localizedDescription, isError: true)
                }
            } else {
                alert = AlertContent(
                    title: "The plate takes effect on the next artwork",
                    message: "This wrap's original artwork isn't on disk — it was saved "
                        + "before Wrapybara kept it. Fetch the icon from the site or choose "
                        + "the file again and it will be drawn with the new plate.",
                    isError: false)
            }
        }
        store.update(updated)
    }

    /// The raw artwork for a recompose: the retained copy, or — for a wrap saved
    /// before artwork retention — the file the artwork was originally picked from,
    /// if it's still where it was. A picked file that still exists also becomes
    /// the retained copy, so the next restyle doesn't ask again.
    private func artworkForRecomposing(_ wrap: Wrap) -> NSImage? {
        if let artwork = exporter.artwork(for: wrap) { return artwork }
        guard let url = wrap.icon.sourceURL, url.isFileURL,
              let image = NSImage(contentsOf: url), image.isValid else { return nil }
        try? exporter.saveArtwork(image, for: wrap)
        return image
    }

    /// The artwork to show in the library, drawn fresh for a monogram wrap.
    func icon(for wrap: Wrap) -> NSImage {
        exporter.resolvedIcon(for: wrap)
    }

    // MARK: Boosts

    func addBoost(to wrap: Wrap) {
        var updated = wrap
        let boost = Boost(name: "New Boost", match: .everywhere)
        updated.boosts.append(boost)
        store.update(updated)
        selectedBoostID = boost.id
    }

    func updateBoost(_ boost: Boost, in wrap: Wrap) {
        var updated = wrap
        if let index = updated.boosts.firstIndex(where: { $0.id == boost.id }) {
            updated.boosts[index] = boost
            updated.boosts[index].updatedAt = Date()
            store.update(updated)
        } else {
            // Not a wrap-local boost, so it's a shared one.
            store.updateSharedBoost(boost)
        }
    }

    func deleteBoost(_ boost: Boost, from wrap: Wrap) {
        var updated = wrap
        updated.boosts.removeAll { $0.id == boost.id }
        store.update(updated)
        if selectedBoostID == boost.id { selectedBoostID = nil }
    }

    func setSharedBoost(_ boostID: UUID, enabled: Bool, in wrap: Wrap) {
        var updated = wrap
        if enabled {
            guard !updated.enabledSharedBoostIDs.contains(boostID) else { return }
            updated.enabledSharedBoostIDs.append(boostID)
        } else {
            updated.enabledSharedBoostIDs.removeAll { $0 == boostID }
        }
        store.update(updated)
    }

    /// Promotes a wrap-local boost onto the shared shelf, and switches it on here.
    func shareBoost(_ boost: Boost, from wrap: Wrap) {
        var promoted = boost
        promoted.id = UUID()
        store.addSharedBoost(promoted)
        var updated = wrap
        updated.boosts.removeAll { $0.id == boost.id }
        updated.enabledSharedBoostIDs.append(promoted.id)
        store.update(updated)
        selectedBoostID = promoted.id
    }
}

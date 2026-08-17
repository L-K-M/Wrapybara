import Foundation

/// The builder's library, loaded once and saved on a short debounce.
///
/// Every mutation goes through here rather than through the views, for one reason:
/// each change has to reach two places — `library.json` (so Wrapybara remembers it)
/// and the per-wrap file in the shared runtime directory (so a *running* site app
/// picks it up without being rebuilt). Doing that in one place is what makes "edit a
/// boost, watch the app change" work.
final class WrapStore: ObservableObject {

    @Published private(set) var library: WrapLibrary

    /// Set when the last load or save failed, for the library window to surface.
    /// Never thrown out of the mutators: losing an edit because a disk write failed
    /// is bad, but throwing out of a SwiftUI action is worse.
    @Published private(set) var lastError: String?

    private let file: JSONFileStore
    private let libraryURL: URL
    private var saveTimer: Timer?
    /// Long enough to coalesce a slider drag, short enough that quitting right after
    /// an edit doesn't need the terminate-time flush to save the day (it still does).
    private let saveDebounce: TimeInterval = 0.4

    init(libraryURL: URL = AppSupport.libraryFileURL, file: JSONFileStore = JSONFileStore()) {
        self.libraryURL = libraryURL
        self.file = file
        self.library = .empty
        load()
    }

    deinit { saveTimer?.invalidate() }

    // MARK: Load / save

    func load() {
        do {
            library = try file.load(WrapLibrary.self, from: libraryURL) ?? .empty
            lastError = nil
        } catch {
            // Keep whatever is in memory rather than replacing a real library with
            // an empty one — an unreadable file is recoverable, an overwritten one
            // isn't.
            lastError = "Couldn't read the library: \(error.localizedDescription)"
        }
    }

    /// Writes now, cancelling any pending debounced save. Call from
    /// `applicationWillTerminate`.
    func flush() {
        saveTimer?.invalidate()
        saveTimer = nil
        do {
            try file.save(library, to: libraryURL)
            lastError = nil
        } catch {
            lastError = "Couldn't save the library: \(error.localizedDescription)"
        }
    }

    private func scheduleSave() {
        saveTimer?.invalidate()
        let timer = Timer(timeInterval: saveDebounce, repeats: false) { [weak self] _ in
            self?.flush()
        }
        RunLoop.main.add(timer, forMode: .common)
        saveTimer = timer
    }

    // MARK: Mutation

    func add(_ wrap: Wrap) {
        library.wraps.append(wrap)
        didChange(wrapIDs: [wrap.id])
    }

    /// Replaces the wrap with the same `id`. A no-op if it's gone (deleted in
    /// another window while an editor was open).
    func update(_ wrap: Wrap) {
        guard let index = library.wraps.firstIndex(where: { $0.id == wrap.id }) else { return }
        var updated = wrap
        updated.updatedAt = Date()
        library.wraps[index] = updated
        didChange(wrapIDs: [updated.id])
    }

    func remove(wrapID: UUID) {
        library.wraps.removeAll { $0.id == wrapID }
        // Leave the built `.app` alone — deleting a library entry is not a request to
        // delete an application the user may have in their Dock. The library window
        // offers that as a separate, explicit action.
        try? file.remove(at: AppSupport.runtimeConfigurationURL(forWrapID: wrapID))
        try? file.remove(at: AppSupport.iconURL(forWrapID: wrapID))
        scheduleSave()
    }

    // Note: there is no reordering method here. `move(fromOffsets:toOffset:)` comes from
    // SwiftUI rather than Foundation, and this file has no other reason to import it —
    // so when the library list gains drag-to-reorder, the reorder belongs in
    // `LibraryModel` (which already imports SwiftUI) writing back through `update`.

    // MARK: Shared boosts

    func addSharedBoost(_ boost: Boost) {
        library.sharedBoosts.append(boost)
        // A new shared boost is off in every wrap until switched on, so nothing to
        // republish — but a rename or an edit does affect every wrap using it.
        scheduleSave()
    }

    func updateSharedBoost(_ boost: Boost) {
        guard let index = library.sharedBoosts.firstIndex(where: { $0.id == boost.id }) else { return }
        var updated = boost
        updated.updatedAt = Date()
        library.sharedBoosts[index] = updated
        didChange(wrapIDs: wrapIDsUsing(sharedBoostID: boost.id))
    }

    func removeSharedBoost(id: UUID) {
        let affected = wrapIDsUsing(sharedBoostID: id)
        library.sharedBoosts.removeAll { $0.id == id }
        for index in library.wraps.indices {
            library.wraps[index].enabledSharedBoostIDs.removeAll { $0 == id }
        }
        didChange(wrapIDs: affected)
    }

    func wrapIDsUsing(sharedBoostID id: UUID) -> [UUID] {
        library.wraps.filter { $0.enabledSharedBoostIDs.contains(id) }.map(\.id)
    }

    // MARK: Runtime publication

    /// Writes the resolved configuration for every wrap in `wrapIDs` into the shared
    /// runtime directory, then schedules a library save.
    private func didChange(wrapIDs: [UUID]) {
        for id in wrapIDs {
            guard let wrap = library.wrap(id: id) else { continue }
            do {
                try publishRuntimeConfiguration(for: wrap)
            } catch {
                lastError = "Couldn't update \(wrap.name): \(error.localizedDescription)"
            }
        }
        scheduleSave()
    }

    /// The resolved configuration for `wrap` — what the exporter bakes in and what
    /// the runtime reads.
    func configuration(for wrap: Wrap) -> WrapConfiguration {
        WrapConfiguration.resolved(wrap,
                                  boosts: library.resolvedBoosts(for: wrap),
                                  generatedBy: Bundle.main.shortVersionString)
    }

    /// Publishes `wrap`'s configuration to the shared runtime directory, where any
    /// already-running copy of the generated app will notice it.
    func publishRuntimeConfiguration(for wrap: Wrap) throws {
        try file.save(configuration(for: wrap),
                      to: AppSupport.runtimeConfigurationURL(forWrapID: wrap.id))
    }

    /// Re-publishes every wrap. Used after a Wrapybara upgrade, so running apps get
    /// configurations written by the current format.
    func publishAllRuntimeConfigurations() {
        for wrap in library.wraps {
            try? publishRuntimeConfiguration(for: wrap)
        }
    }

    // MARK: Naming helpers

    /// A wrap for `url`, with its name, identifier and icon filled in and not
    /// colliding with anything already in the library.
    func makeWrap(for url: URL, name proposedName: String? = nil) -> Wrap {
        let suggested = proposedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = (suggested?.isEmpty == false ? suggested : nil)
            ?? URLNormalizer.suggestedName(for: url)
        let uniqueName = AppNameSanitizer.uniqueFileName(for: name, avoiding: library.usedAppFileNames)
        let identifier = BundleIdentifierGenerator.uniqueIdentifier(
            for: url, name: uniqueName, avoiding: library.usedBundleIdentifiers)
        return Wrap(name: uniqueName,
                    homeURL: url,
                    bundleIdentifier: identifier,
                    icon: .monogram(for: uniqueName))
    }
}

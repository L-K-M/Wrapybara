import Foundation

/// Remembers which pages a site app's windows were on.
///
/// Stores `WKWebView.interactionState` blobs — which carry the whole back-forward
/// list, the scroll position and unsubmitted form state — so reopening the app really
/// does put you back where you were, rather than reloading the home page and calling
/// it restoration.
///
/// Kept in the app's own `UserDefaults` rather than the shared Application Support
/// directory: this is per-app state, and a wrap's session has no business being
/// readable by Wrapybara or by another wrap.
enum SessionStore {

    /// Cap on how many windows are remembered. Restoring forty tabs at launch would
    /// spawn forty web content processes at once.
    static let maximumWindows = 12

    /// Cap on one window's state. `interactionState` for a long session with large
    /// form state can grow; `UserDefaults` is the wrong place for megabytes, and a
    /// blob this big means something has gone wrong rather than that the user has a
    /// lot of history.
    static let maximumStateBytes = 2 * 1024 * 1024

    private static func key(wrapID: UUID) -> String {
        "SessionStore.\(wrapID.uuidString).windows"
    }

    static func save(_ states: [Data], wrapID: UUID,
                     defaults: UserDefaults = .standard) {
        let usable = states
            .filter { !$0.isEmpty && $0.count <= maximumStateBytes }
            .prefix(maximumWindows)
        guard !usable.isEmpty else {
            clear(wrapID: wrapID, defaults: defaults)
            return
        }
        defaults.set(Array(usable), forKey: key(wrapID: wrapID))
    }

    static func load(wrapID: UUID, defaults: UserDefaults = .standard) -> [Data] {
        guard let stored = defaults.array(forKey: key(wrapID: wrapID)) as? [Data] else { return [] }
        return stored
            .filter { !$0.isEmpty && $0.count <= maximumStateBytes }
            .prefix(maximumWindows)
            .map { $0 }
    }

    static func clear(wrapID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(wrapID: wrapID))
    }
}

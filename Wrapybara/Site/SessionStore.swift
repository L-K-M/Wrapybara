import Foundation

/// Remembers where a site app's windows were, and what they were showing.
///
/// Two things are stored per window. `geometry` — frame, screen, full screen — so
/// a relaunch reopens the window *where it was* rather than centered on the main
/// display. `interactionState` — `WKWebView.interactionState`, which carries the
/// whole back-forward list, the scroll position and unsubmitted form state — so
/// it reopens *on what it was showing*, rather than reloading the home page and
/// calling it restoration.
///
/// Kept in the app's own `UserDefaults` rather than the shared Application Support
/// directory: this is per-app state, and a wrap's session has no business being
/// readable by Wrapybara or by another wrap. Not `NSWindowRestoration`, either —
/// that machinery is switched off by the system's "Close windows when quitting an
/// application" setting, and a site app's session should survive regardless.
enum SessionStore {

    /// Cap on how many windows are remembered. Restoring forty tabs at launch would
    /// spawn forty web content processes at once.
    static let maximumWindows = 12

    /// Cap on one window's state. `interactionState` for a long session with large
    /// form state can grow; `UserDefaults` is the wrong place for megabytes, and a
    /// blob this big means something has gone wrong rather than that the user has a
    /// lot of history.
    static let maximumStateBytes = 2 * 1024 * 1024

    /// One remembered window: where it was, and what it was showing. Either half
    /// can be absent — a session saved with page restore off keeps only the place;
    /// a session saved by an older runtime has only the pages.
    struct WindowState: Codable, Equatable {
        var geometry: WindowGeometry?
        var interactionState: Data?

        init(geometry: WindowGeometry?, interactionState: Data?) {
            self.geometry = geometry
            self.interactionState = interactionState
        }

        enum CodingKeys: String, CodingKey {
            case geometry, interactionState
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self.geometry = c.optional(.geometry)
            self.interactionState = c.optional(.interactionState)
        }
    }

    private static func key(wrapID: UUID) -> String {
        "SessionStore.\(wrapID.uuidString).windows.v2"
    }

    /// Where the previous runtime stored its session: an array of interaction
    /// blobs, no geometry. Read once as a fallback, retired on the next save.
    private static func legacyKey(wrapID: UUID) -> String {
        "SessionStore.\(wrapID.uuidString).windows"
    }

    static func save(_ states: [WindowState], wrapID: UUID,
                     defaults: UserDefaults = .standard) {
        let usable = trimmed(states).prefix(maximumWindows)
        guard !usable.isEmpty, let data = try? JSONEncoder().encode(Array(usable)) else {
            clear(wrapID: wrapID, defaults: defaults)
            return
        }
        defaults.set(data, forKey: key(wrapID: wrapID))
        // The previous runtime reads the old key. A session left there would
        // resurrect stale pages if this app ever ran from an older build again.
        defaults.removeObject(forKey: legacyKey(wrapID: wrapID))
    }

    static func load(wrapID: UUID, defaults: UserDefaults = .standard) -> [WindowState] {
        if let data = defaults.data(forKey: key(wrapID: wrapID)),
           let states = try? JSONDecoder().decode([WindowState].self, from: data) {
            return Array(trimmed(states).prefix(maximumWindows))
        }
        // A session written by the previous runtime: interaction blobs only, under
        // the old key. Their pages still come back; the windows just open where a
        // first window opens.
        let legacy = (defaults.array(forKey: legacyKey(wrapID: wrapID)) as? [Data] ?? [])
            .filter { !$0.isEmpty && $0.count <= maximumStateBytes }
            .prefix(maximumWindows)
            .map { WindowState(geometry: nil, interactionState: $0) }
        return Array(legacy)
    }

    static func clear(wrapID: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(wrapID: wrapID))
        defaults.removeObject(forKey: legacyKey(wrapID: wrapID))
    }

    /// Drops the halves not worth remembering — an interaction blob that is empty
    /// or has outgrown `maximumStateBytes`, and a geometry with no rectangle in
    /// it — and then any window left with nothing at all.
    private static func trimmed(_ states: [WindowState]) -> [WindowState] {
        states.map { state in
            var trimmed = state
            if let blob = trimmed.interactionState,
               blob.isEmpty || blob.count > maximumStateBytes {
                trimmed.interactionState = nil
            }
            if trimmed.geometry?.isUsable != true {
                trimmed.geometry = nil
            }
            return trimmed
        }
        .filter { $0.geometry != nil || $0.interactionState != nil }
    }
}

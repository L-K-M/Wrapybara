import Foundation

/// The builder's document: every wrap, plus the shelf of boosts that wraps can
/// share.
///
/// Only Wrapybara reads this. Generated apps read a `WrapConfiguration` instead —
/// see that type for why the two are separate.
struct WrapLibrary: Codable, Equatable {

    static let currentFormatVersion = 1

    var formatVersion: Int
    var wraps: [Wrap]
    /// Boosts that aren't owned by one wrap. A "hide cookie banners" or "Iowan Old
    /// Style everywhere" boost is written once here and switched on per wrap.
    var sharedBoosts: [Boost]

    init(formatVersion: Int = WrapLibrary.currentFormatVersion,
         wraps: [Wrap] = [],
         sharedBoosts: [Boost] = []) {
        self.formatVersion = formatVersion
        self.wraps = wraps
        self.sharedBoosts = sharedBoosts
    }

    static let empty = WrapLibrary()

    // MARK: Resolution

    /// The ordered boost list for `wrap`: its own boosts first, then the shared
    /// boosts it opted into, in library order.
    ///
    /// Wrap-local first is deliberate. Later rules win in CSS, so a shared "make
    /// everything Helvetica" boost would otherwise override the per-wrap tweak the
    /// user wrote specifically to escape it. Shared boosts are the baseline; local
    /// boosts are the correction.
    func resolvedBoosts(for wrap: Wrap) -> [Boost] {
        let enabled = Set(wrap.enabledSharedBoostIDs)
        return wrap.boosts + sharedBoosts.filter { enabled.contains($0.id) }
    }

    /// The wrap with `id`, if it's still in the library.
    func wrap(id: UUID) -> Wrap? { wraps.first { $0.id == id } }

    /// Every bundle identifier currently in use, for collision avoidance when
    /// naming a new wrap.
    var usedBundleIdentifiers: Set<String> {
        Set(wraps.map(\.bundleIdentifier).filter { !$0.isEmpty })
    }

    /// Every `.app` file name currently in use, so two wraps can't both want
    /// `Mail.app`.
    var usedAppFileNames: Set<String> {
        Set(wraps.map(\.appFileName).filter { !$0.isEmpty })
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case formatVersion, wraps, sharedBoosts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.formatVersion = c.value(.formatVersion, or: Self.currentFormatVersion)
        self.wraps = c.value(.wraps, or: [Wrap]())
        self.sharedBoosts = c.value(.sharedBoosts, or: [Boost]())
    }
}

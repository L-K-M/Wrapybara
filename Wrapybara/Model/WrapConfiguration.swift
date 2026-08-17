import Foundation

/// Everything a generated app needs to run itself: exactly what the exporter
/// writes and exactly what the runtime reads.
///
/// The runtime never sees `WrapLibrary`. That matters, because a generated app has
/// to keep working when Wrapybara is deleted, when it's built by one version and
/// run under another, and when the user has no library at all.
///
/// **`boosts` is authoritative.** The exporter resolves the wrap's own boosts and
/// the shared boosts it opted into into one ordered list here, and blanks
/// `wrap.boosts` on the way out (`resolved(_:boosts:)` does both), so there is
/// never a question of which list the runtime obeys.
struct WrapConfiguration: Codable, Equatable {

    /// Bumped only for a change the *older* runtime can't survive. Additive
    /// changes don't need it — every stored type decodes missing keys as defaults
    /// (see `DecodingDefaults`).
    static let currentFormatVersion = 1

    var formatVersion: Int
    var wrap: Wrap
    /// The fully resolved, ordered boost list. Wrap-local boosts first, then the
    /// shared ones, so a wrap-specific tweak can override a shared theme.
    var boosts: [Boost]
    /// The Wrapybara `CFBundleShortVersionString` that wrote this file.
    var generatedBy: String
    var generatedAt: Date

    init(formatVersion: Int = WrapConfiguration.currentFormatVersion,
         wrap: Wrap,
         boosts: [Boost],
         generatedBy: String,
         generatedAt: Date = Date()) {
        self.formatVersion = formatVersion
        self.wrap = wrap
        self.boosts = boosts
        self.generatedBy = generatedBy
        self.generatedAt = generatedAt
    }

    /// Builds a configuration from a wrap and its resolved boost list, moving the
    /// boosts out of the wrap so only one list survives the trip to disk.
    static func resolved(_ wrap: Wrap, boosts: [Boost], generatedBy: String,
                         generatedAt: Date = Date()) -> WrapConfiguration {
        var stripped = wrap
        stripped.boosts = []
        stripped.enabledSharedBoostIDs = []
        return WrapConfiguration(wrap: stripped, boosts: boosts,
                                 generatedBy: generatedBy, generatedAt: generatedAt)
    }

    /// Whether this runtime can read the file at all. A file from the future is
    /// refused rather than half-understood.
    var isReadable: Bool { formatVersion <= Self.currentFormatVersion }

    /// The boosts that apply to `url`, in application order.
    func boosts(matching url: URL) -> [Boost] {
        boosts.filter { $0.isEnabled && !$0.isEmpty && BoostMatcher.matches($0.match, url: url) }
    }

    // MARK: Picking between two copies

    /// Chooses between the copy baked into the app bundle at build time and the
    /// copy in the shared store that Wrapybara rewrites on every edit.
    ///
    /// Newest `generatedAt` wins, which gets both directions right: editing a boost
    /// in Wrapybara beats the baked-in seed, and *rebuilding* the app beats a stale
    /// store entry left over from a wrap that was deleted and recreated. An
    /// unreadable (future-format) candidate is ignored rather than preferred.
    static func newer(bundled: WrapConfiguration?, stored: WrapConfiguration?) -> WrapConfiguration? {
        let candidates = [bundled, stored].compactMap { $0 }.filter(\.isReadable)
        return candidates.max { $0.generatedAt < $1.generatedAt }
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case formatVersion, wrap, boosts, generatedBy, generatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `wrap` is the one field with no meaningful default — a configuration
        // without it describes nothing, so this one is allowed to throw.
        self.wrap = try c.decode(Wrap.self, forKey: .wrap)
        self.formatVersion = c.value(.formatVersion, or: Self.currentFormatVersion)
        self.boosts = c.value(.boosts, or: [Boost]())
        self.generatedBy = c.value(.generatedBy, or: "unknown")
        self.generatedAt = c.value(.generatedAt, or: Date.distantPast)
    }
}

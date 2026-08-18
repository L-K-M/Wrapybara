import Foundation

/// Where a wrap's artwork came from, and what to draw if there isn't any.
///
/// The bitmap itself is *not* in here. Resolved artwork is a PNG on disk at
/// `AppSupport.iconURL(for:)`, so the library JSON stays small and diffable; this
/// records only the provenance the UI needs — enough to offer "refresh from the
/// site" or to redraw the monogram after a rename.
struct WrapIcon: Codable, Equatable {

    enum Origin: String, Codable, Equatable {
        /// No artwork on disk: draw initials on a tinted plate.
        case monogram
        /// The user dropped in or chose an image file.
        case pickedFile
        /// Pulled from the site's web app manifest, `apple-touch-icon`, or favicon.
        case fetchedFromSite
    }

    var origin: Origin
    /// The exact image URL the artwork came from, so "Refresh Icon" can re-fetch
    /// the same asset instead of re-crawling the site.
    var sourceURL: URL?
    /// The monogram plate color, `#RRGGBB`.
    var tintHex: String
    /// One or two letters for the monogram.
    var monogram: String
    /// The user's chosen plate behind the artwork. `nil` is *automatic*: a
    /// gradient derived from `tintHex`. See `IconPlate`.
    var plate: IconPlate?

    init(origin: Origin = .monogram,
         sourceURL: URL? = nil,
         tintHex: String = WrapIcon.defaultTintHex,
         monogram: String = "",
         plate: IconPlate? = nil) {
        self.origin = origin
        self.sourceURL = sourceURL
        self.tintHex = tintHex
        self.monogram = monogram
        self.plate = plate
    }

    /// Wrapybara's own warm brown, so an un-iconed wrap still looks deliberate.
    static let defaultTintHex = "#8B5A2B"

    /// A monogram icon whose letters and tint are derived from `name`.
    static func monogram(for name: String) -> WrapIcon {
        WrapIcon(origin: .monogram,
                 tintHex: tintHex(for: name),
                 monogram: initials(for: name))
    }

    /// Up to two letters: the initials of the first two words, or the first two
    /// characters of a single-word name.
    ///
    /// Pure and unit-tested — it runs on every un-iconed wrap in the library list.
    static func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" || $0 == "." })
            .filter { $0.contains(where: { $0.isLetter || $0.isNumber }) }
        if words.count >= 2 {
            let first = words[0].first.map(String.init) ?? ""
            let second = words[1].first.map(String.init) ?? ""
            return (first + second).uppercased()
        }
        guard let word = words.first else { return "" }
        return String(word.prefix(2)).uppercased()
    }

    /// A stable tint for `name`, so the same site always gets the same color and
    /// two wraps in a list are unlikely to share one.
    ///
    /// Uses a fixed palette indexed by a deterministic hash of the name — *not*
    /// `String.hashValue`, which is seeded per process and would repaint every icon
    /// on relaunch.
    static func tintHex(for name: String) -> String {
        let key = name.lowercased()
        guard !key.isEmpty else { return defaultTintHex }
        var hash: UInt64 = 5381
        for byte in Array(key.utf8) {
            hash = (hash &* 33) &+ UInt64(byte)   // djb2, wrapping
        }
        return palette[Int(hash % UInt64(palette.count))]
    }

    /// Muted, mid-dark plates that white initials read against.
    static let palette = [
        "#8B5A2B", "#2F6F4F", "#2C5F8A", "#6A4C93",
        "#A4453A", "#7A6A2F", "#3F6F73", "#8A4C6B",
    ]

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case origin, sourceURL, tintHex, monogram, plate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.origin = c.value(.origin, or: .monogram)
        self.sourceURL = c.optional(.sourceURL)
        self.tintHex = c.value(.tintHex, or: WrapIcon.defaultTintHex)
        self.monogram = c.value(.monogram, or: "")
        // Missing on every icon written before plates were editable — exactly
        // the "automatic" the nil represents, so old libraries keep their look.
        self.plate = c.optional(.plate)
    }
}

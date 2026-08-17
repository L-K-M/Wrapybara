import Foundation

/// One piece of artwork a site advertises, with enough information to rank it.
struct IconCandidate: Equatable, Identifiable, Hashable {

    /// Where the artwork was advertised, which is most of what decides how good it
    /// is likely to be.
    enum Source: String, Equatable, Hashable {
        /// An `icons[]` entry in a web app manifest — a PWA's own idea of its icon,
        /// and the best thing to use.
        case webAppManifest
        /// `<link rel="apple-touch-icon">` — drawn for an iOS home screen, so square,
        /// full-bleed and usually 180px or better.
        case appleTouchIcon
        /// `<link rel="icon">` / `shortcut icon`.
        case linkIcon
        /// `<meta property="og:image">` — often a wide social card rather than an
        /// icon, so ranked last and only used when nothing else exists.
        case openGraphImage
        /// `/favicon.ico`, guessed rather than advertised.
        case rootFavicon

        /// Higher is better. Ties are broken by pixel size.
        var priority: Int {
            switch self {
            case .webAppManifest: return 50
            case .appleTouchIcon: return 40
            case .linkIcon: return 30
            case .rootFavicon: return 20
            case .openGraphImage: return 10
            }
        }
    }

    var url: URL
    var source: Source
    /// The largest edge the site claims, from a `sizes` attribute or a manifest
    /// entry. `nil` when unstated — which is not the same as small.
    var declaredEdge: Int?
    /// The MIME type the site claims, if any.
    var mimeType: String?

    var id: String { url.absoluteString + "|" + source.rawValue }

    /// Whether this is a format `NSImage` can decode. SVG is excluded: `NSImage`
    /// can load it, but only at its intrinsic size, which for an icon designed to
    /// scale is often 16pt — rasterising that to 1024 looks worse than the monogram
    /// fallback.
    var isUsableFormat: Bool {
        let type = (mimeType ?? "").lowercased()
        if type.contains("svg") { return false }
        let ext = url.pathExtension.lowercased()
        return !["svg", "svgz"].contains(ext)
    }

    /// Sorts candidates best-first: by source, then by declared size, then by URL so
    /// the order is stable for a given page (and therefore testable).
    static func ranked(_ candidates: [IconCandidate]) -> [IconCandidate] {
        candidates
            .filter(\.isUsableFormat)
            .sorted { lhs, rhs in
                if lhs.source.priority != rhs.source.priority {
                    return lhs.source.priority > rhs.source.priority
                }
                let lhsEdge = lhs.declaredEdge ?? 0
                let rhsEdge = rhs.declaredEdge ?? 0
                if lhsEdge != rhsEdge { return lhsEdge > rhsEdge }
                return lhs.url.absoluteString < rhs.url.absoluteString
            }
    }
}

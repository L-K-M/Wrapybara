import Foundation

/// Where a boost applies.
///
/// Stored as a `kind` + a `pattern` string rather than an enum with associated
/// values, so the JSON stays flat, diffable and hand-editable, and so switching a
/// boost from (say) *domain* to *glob* keeps whatever the user already typed.
///
/// Matching itself lives in `BoostMatcher`, which is pure and unit-tested.
struct BoostMatch: Codable, Equatable, Hashable {

    enum Kind: String, Codable, CaseIterable, Identifiable {
        /// Every page the wrap loads.
        case everywhere
        /// A host, optionally including its subdomains (`example.com`).
        case domain
        /// A literal prefix of the full URL (`https://example.com/docs`).
        case urlPrefix
        /// A shell-style glob over the full URL (`https://example.com/*/settings`).
        case glob
        /// An ICU regular expression over the full URL.
        case regex

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .everywhere: return "Every page"
            case .domain: return "Domain"
            case .urlPrefix: return "URL starts with"
            case .glob: return "URL matches (glob)"
            case .regex: return "URL matches (regex)"
            }
        }

        /// Whether this kind reads `pattern` at all (the picker hides the field
        /// for `.everywhere`).
        var usesPattern: Bool { self != .everywhere }
    }

    var kind: Kind
    var pattern: String
    /// `.domain` only: also match `*.pattern`. On by default — someone typing
    /// `github.com` means the site, not that exact host label.
    var includesSubdomains: Bool
    /// `.glob` and `.regex` only. Hosts are always compared case-insensitively
    /// regardless, because hostnames are.
    var isCaseSensitive: Bool

    init(kind: Kind = .everywhere,
         pattern: String = "",
         includesSubdomains: Bool = true,
         isCaseSensitive: Bool = false) {
        self.kind = kind
        self.pattern = pattern
        self.includesSubdomains = includesSubdomains
        self.isCaseSensitive = isCaseSensitive
    }

    /// Matches every page — the default for a boost created from the wrap editor,
    /// where "this site" is already the whole scope.
    static let everywhere = BoostMatch(kind: .everywhere)

    /// Matches `host` and its subdomains.
    static func domain(_ host: String) -> BoostMatch {
        BoostMatch(kind: .domain, pattern: host)
    }

    /// A short human description, for the boost list's subtitle.
    var summary: String {
        switch kind {
        case .everywhere:
            return "Every page"
        case .domain:
            let host = pattern.isEmpty ? "—" : pattern
            return includesSubdomains ? "\(host) and subdomains" : host
        case .urlPrefix:
            return "URLs starting \(pattern)"
        case .glob:
            return "URLs matching \(pattern)"
        case .regex:
            return "URLs matching /\(pattern)/"
        }
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case kind, pattern, includesSubdomains, isCaseSensitive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.kind = c.value(.kind, or: Kind.everywhere)
        self.pattern = c.value(.pattern, or: "")
        self.includesSubdomains = c.value(.includesSubdomains, or: true)
        self.isCaseSensitive = c.value(.isCaseSensitive, or: false)
    }
}

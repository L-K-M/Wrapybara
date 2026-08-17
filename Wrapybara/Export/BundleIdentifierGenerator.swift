import Foundation

/// Derives a generated app's `CFBundleIdentifier`.
///
/// This value matters more than it looks. macOS keys a lot off it: the app's
/// `UserDefaults` domain, its `~/Library/Containers`-adjacent WebKit data
/// directory (and therefore its cookies and logins), Launch Services, Notification
/// Center's per-app permission, and the Dock's idea of which tile is which. Two
/// wraps sharing an identifier would share a session; changing one after the fact
/// would silently log the user out. So it is derived once, deterministically, and
/// then frozen in `Wrap.bundleIdentifier`.
enum BundleIdentifierGenerator {

    /// The prefix for every generated app. Distinct from Wrapybara's own
    /// `com.wrapybara.Wrapybara` so a wrap can never collide with the builder.
    static let prefix = "com.wrapybara.site"

    /// A deterministic identifier for a site: `com.wrapybara.site.<host>.<name>`,
    /// with the host's labels reversed the way reverse-DNS wants them.
    ///
    /// `claude.ai` + "Claude" → `com.wrapybara.site.ai.claude.claude`
    static func identifier(forHost host: String, name: String) -> String {
        let hostLabels = BoostMatcher.normalizedHost(host)
            .split(separator: ".")
            .map { component(String($0)) }
            .filter { !$0.isEmpty }

        var parts = [prefix]
        parts.append(contentsOf: hostLabels.reversed())

        // Append the name so two wraps of one site ("Gmail Work", "Gmail Personal")
        // get distinct identifiers — but not when it merely repeats the site label,
        // which would give `…ai.claude.claude`.
        let nameComponent = component(name)
        if !nameComponent.isEmpty, nameComponent != parts.last {
            parts.append(nameComponent)
        }

        let identifier = parts.joined(separator: ".")
        return identifier == prefix ? "\(prefix).app" : identifier
    }

    /// The identifier for a wrap of `url`.
    static func identifier(for url: URL, name: String) -> String {
        identifier(forHost: url.host ?? "", name: name)
    }

    /// An identifier not already in `existing`, by appending `-2`, `-3`, ….
    ///
    /// A suffix rather than a rename, because the base identifier is derived from
    /// the site and two wraps of the same site (a work and a personal account, say)
    /// genuinely want to differ only in this.
    static func uniqueIdentifier(for url: URL, name: String,
                                 avoiding existing: Set<String>) -> String {
        let base = identifier(for: url, name: name)
        guard existing.contains(base) else { return base }
        for index in 2...999 {
            let candidate = "\(base)-\(index)"
            if !existing.contains(candidate) { return candidate }
        }
        return "\(base)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Folds a string into one reverse-DNS component: lowercase, ASCII
    /// alphanumerics and hyphens only, no leading digit or hyphen.
    ///
    /// Bundle identifiers are documented as `A-Za-z0-9.-` only. Non-ASCII is
    /// transliterated where possible (so `Café` gives `cafe`, not `caf`) and
    /// dropped where it isn't.
    static func component(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var result = ""
        var lastWasHyphen = false
        for scalar in folded.unicodeScalars {
            let character = Character(scalar)
            if character.isASCII, character.isLetter || character.isNumber {
                result.append(character)
                lastWasHyphen = false
            } else if !result.isEmpty, !lastWasHyphen {
                result.append("-")
                lastWasHyphen = true
            }
        }
        while result.hasSuffix("-") { result.removeLast() }
        // A leading digit is fine — Apple's rules allow `A-Za-z0-9.-` in any order —
        // but a leading hyphen isn't, and it's what a name like "-beta" would leave.
        while result.hasPrefix("-") { result.removeFirst() }
        return result.lowercased()
    }
}

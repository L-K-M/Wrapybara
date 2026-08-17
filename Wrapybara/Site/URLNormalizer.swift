import Foundation

/// Turns what a person types into a URL a web view can load.
///
/// Used by the "new wrap" field and by ⌘L in a site app, so `claude.ai`,
/// `www.claude.ai/new` and `https://claude.ai` all end up in the right place —
/// and so a stray search phrase doesn't get loaded as a hostname.
enum URLNormalizer {

    /// A normalised absolute `http(s)` URL for `input`, or `nil` if it doesn't look
    /// like an address at all.
    ///
    /// Bare input is promoted to `https://`, never `http://`: a wrap is a long-lived
    /// app and shouldn't start life on a downgradeable scheme. A site that is
    /// genuinely HTTP-only still works — the user types the scheme.
    static func url(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Reject anything with whitespace inside: that's a search phrase, not a host.
        guard !trimmed.contains(where: \.isWhitespace) else { return nil }

        if let scheme = scheme(of: trimmed) {
            guard scheme == "http" || scheme == "https" else { return nil }
            return URL(string: trimmed)
        }

        // No scheme. It has to at least look like a host: a dot inside it, or
        // `localhost`.
        let hostPart = trimmed.split(separator: "/", maxSplits: 1).first.map(String.init) ?? trimmed
        let bareHost = hostPart.split(separator: ":").first.map(String.init) ?? hostPart
        let looksLikeHost = bareHost == "localhost"
            || (bareHost.contains(".") && !bareHost.hasPrefix(".") && !bareHost.hasSuffix("."))
        guard looksLikeHost else { return nil }

        return URL(string: "https://" + trimmed)
    }

    /// The lowercased scheme of `input` if it carries one.
    ///
    /// Deliberately not `URL(string:)?.scheme` — that reports a scheme for things
    /// like `mail.google.com:443/foo`, where the "scheme" is really a host.
    static func scheme(of input: String) -> String? {
        guard let separator = input.range(of: "://") else { return nil }
        let candidate = String(input[input.startIndex..<separator.lowerBound]).lowercased()
        guard !candidate.isEmpty,
              candidate.first?.isLetter == true,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." })
        else { return nil }
        return candidate
    }

    /// A short display form for a toolbar or a list row: host plus a truncated path,
    /// with `www.` and a trailing slash dropped.
    static func displayString(for url: URL, maxLength: Int = 60) -> String {
        var host = url.host ?? url.absoluteString
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        if path == "/" { path = "" }
        var text = host + path
        if let query = url.query, !query.isEmpty { text += "?…" }
        guard text.count > maxLength else { return text }
        return String(text.prefix(maxLength - 1)) + "…"
    }

    /// A name to suggest for a wrap of `url`: the registrable-looking label of the
    /// host, capitalised (`mail.proton.me` → `Proton`, `claude.ai` → `Claude`).
    ///
    /// A heuristic, not a public-suffix lookup — it just has to put something
    /// sensible in the name field for the user to correct.
    static func suggestedName(for url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        // An IPv6 literal has no useful label to offer — leave the name to the
        // site (the caller falls back to the manifest/<title>, then "Web App").
        if host.contains(":") { return "" }
        let labels = host.split(separator: ".").map(String.init)
        guard !labels.isEmpty else { return "" }

        // Drop the public-suffix-ish tail. Two-label suffixes like `co.uk` mean the
        // interesting label is third from the end.
        let multiPartSuffixes: Set<String> = ["co", "com", "org", "net", "gov", "edu", "ac"]
        var index = labels.count - 2
        if labels.count >= 3, multiPartSuffixes.contains(labels[labels.count - 2]) {
            index = labels.count - 3
        }
        let label = (index >= 0 && index < labels.count) ? labels[index] : labels[0]
        guard !label.isEmpty else { return "" }
        // Every label being ASCII digits is the real IP signal — TLDs are never
        // numeric, so a mixed host like "163.com" still gets its label ("163"),
        // while "192.168.1.1" is named honestly. (ASCII digits only: `isNumber`
        // alone would also match non-ASCII numerics like ² or ٣, which can appear
        // in IDN labels and say nothing about being an IP.)
        if labels.allSatisfy({ $0.allSatisfy { $0.isASCII && $0.isNumber } }) { return host }
        return label.prefix(1).uppercased() + label.dropFirst()
    }
}

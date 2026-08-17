import Foundation

/// Decides whether a `BoostMatch` applies to a URL.
///
/// Pure and free of AppKit/WebKit so the whole matching table can be unit-tested;
/// the runtime calls it once per navigation, on the main thread, so it also has to
/// stay cheap — hence the compiled-regex cache.
enum BoostMatcher {

    static func matches(_ match: BoostMatch, url: URL) -> Bool {
        switch match.kind {
        case .everywhere:
            return true

        case .domain:
            return matchesDomain(pattern: match.pattern,
                                 includingSubdomains: match.includesSubdomains,
                                 url: url)

        case .urlPrefix:
            let pattern = match.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pattern.isEmpty else { return false }
            // URL prefixes are compared case-sensitively past the host, because
            // paths are case-sensitive on most servers. The host part isn't, but
            // splitting the comparison at the authority boundary buys little over
            // just telling people to paste a real URL.
            return url.absoluteString.hasPrefix(pattern)

        case .glob:
            guard let regex = compiledGlob(match) else { return false }
            return firstMatch(regex, in: url.absoluteString)

        case .regex:
            guard let regex = compiledRegex(match) else { return false }
            return firstMatch(regex, in: url.absoluteString)
        }
    }

    /// Whether `url`'s host is `pattern` — or a subdomain of it, when asked.
    ///
    /// Hostnames are case-insensitive, and a stored pattern may have arrived with a
    /// scheme or a trailing slash attached (people paste URLs into fields labelled
    /// "domain"), so both sides are normalised first.
    static func matchesDomain(pattern: String, includingSubdomains: Bool, url: URL) -> Bool {
        let host = (url.host ?? "").lowercased()
        let wanted = normalizedHost(pattern)
        guard !host.isEmpty, !wanted.isEmpty else { return false }
        if host == wanted { return true }
        return includingSubdomains && host.hasSuffix("." + wanted)
    }

    /// Strips a scheme, credentials, port, path and leading dots off something the
    /// user typed into a host field.
    static func normalizedHost(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let schemeEnd = value.range(of: "://") {
            value = String(value[schemeEnd.upperBound...])
        }
        // A protocol-relative paste (`//example.com`) has no scheme to strip but does
        // have leading slashes, which the path split below would otherwise read as "the
        // host is empty".
        while value.hasPrefix("/") { value.removeFirst() }
        if let at = value.lastIndex(of: "@") {
            value = String(value[value.index(after: at)...])
        }
        if let slash = value.firstIndex(of: "/") {
            value = String(value[..<slash])
        }
        // An IPv6 literal keeps its brackets; only strip a port from a plain host.
        if !value.hasPrefix("["), let colon = value.firstIndex(of: ":") {
            value = String(value[..<colon])
        }
        while value.hasPrefix(".") { value.removeFirst() }
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    // MARK: Glob

    /// Translates a shell-style glob into an anchored regular expression.
    ///
    /// `*` matches any run of characters, `?` exactly one, and everything else is
    /// literal — so a pattern full of `.` and `?` from a real URL can't accidentally
    /// become a regex metacharacter.
    static func regexPattern(forGlob glob: String) -> String {
        var pattern = "^"
        for character in glob {
            switch character {
            case "*": pattern += ".*"
            case "?": pattern += "."
            default: pattern += NSRegularExpression.escapedPattern(for: String(character))
            }
        }
        return pattern + "$"
    }

    // MARK: Compiled-expression cache

    /// Compiling a regex per navigation per boost is wasteful, and
    /// `NSRegularExpression` is documented as thread-safe once built. The cache is
    /// keyed by the pattern *and* its case flag, and only ever touched from the
    /// main thread (navigation decisions and the editor's live preview both run
    /// there), so it needs no lock of its own.
    private static var cache: [String: NSRegularExpression] = [:]
    /// A hostile or hand-edited config could name thousands of distinct patterns;
    /// cap the cache so it can't grow without bound in a long-running app.
    private static let cacheLimit = 256

    private static func compiledGlob(_ match: BoostMatch) -> NSRegularExpression? {
        let glob = match.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !glob.isEmpty else { return nil }
        return compiled(regexPattern(forGlob: glob), caseSensitive: match.isCaseSensitive)
    }

    private static func compiledRegex(_ match: BoostMatch) -> NSRegularExpression? {
        let pattern = match.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { return nil }
        return compiled(pattern, caseSensitive: match.isCaseSensitive)
    }

    private static func compiled(_ pattern: String, caseSensitive: Bool) -> NSRegularExpression? {
        let key = (caseSensitive ? "s:" : "i:") + pattern
        if let cached = cache[key] { return cached }
        let options: NSRegularExpression.Options = caseSensitive ? [] : [.caseInsensitive]
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return nil   // an invalid pattern matches nothing rather than everything
        }
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = regex
        return regex
    }

    private static func firstMatch(_ regex: NSRegularExpression, in string: String) -> Bool {
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        return regex.firstMatch(in: string, options: [], range: range) != nil
    }

    /// Drops every compiled expression. Called when the boost list is replaced, and
    /// by tests that need a clean slate.
    static func clearCache() { cache.removeAll() }
}

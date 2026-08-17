import Foundation

/// Pulls the icon and name hints out of a page's HTML, and out of a web app
/// manifest.
///
/// Deliberately a small, forgiving scanner rather than a real HTML parse. Two
/// reasons: this only needs six attributes out of `<head>`, and the alternative
/// available without a dependency — loading the markup into a `WKWebView` and
/// asking the DOM — would mean *running the site's scripts* just to learn its icon
/// URL. Wrapybara refuses to do that: fetching a page the user typed shouldn't
/// execute it.
///
/// Everything here is pure, so the whole table of real-world `<link>` shapes is
/// unit-tested.
enum SiteMarkupParser {

    // MARK: HTML

    /// Icon candidates and a title, from a page's markup.
    ///
    /// - Parameters:
    ///   - html: the markup, however truncated. Only `<head>`-ish content matters.
    ///   - baseURL: for resolving relative hrefs.
    struct PageMetadata: Equatable {
        var title: String?
        var manifestURL: URL?
        var candidates: [IconCandidate]
        var themeColor: String?
    }

    static func parse(html: String, baseURL: URL) -> PageMetadata {
        // Stop at </head> when there is one: the body of a large page is megabytes
        // of content that can't contain a rel=icon that matters.
        let head = html.range(of: "</head", options: [.caseInsensitive])
            .map { String(html[html.startIndex..<$0.lowerBound]) } ?? html

        var candidates: [IconCandidate] = []
        var manifestURL: URL?

        for tag in tags(named: "link", in: head) {
            let rels = (attribute("rel", in: tag) ?? "")
                .lowercased()
                .split(whereSeparator: \.isWhitespace)
                .map(String.init)
            guard let href = attribute("href", in: tag),
                  let resolved = resolve(href, against: baseURL) else { continue }

            if rels.contains("manifest") {
                manifestURL = resolved
                continue
            }

            let source: IconCandidate.Source?
            if rels.contains("apple-touch-icon") || rels.contains("apple-touch-icon-precomposed") {
                source = .appleTouchIcon
            } else if rels.contains("icon") {
                // Catches `rel="icon"` and the legacy `rel="shortcut icon"`, which is
                // two tokens. `mask-icon` is deliberately not here: it's a monochrome
                // Safari pinned-tab silhouette and would make a black square.
                source = .linkIcon
            } else {
                source = nil
            }
            guard let source else { continue }

            candidates.append(IconCandidate(url: resolved,
                                            source: source,
                                            declaredEdge: largestEdge(in: attribute("sizes", in: tag)),
                                            mimeType: attribute("type", in: tag)))
        }

        var themeColor: String?
        var openGraphImage: URL?
        for tag in tags(named: "meta", in: head) {
            let key = (attribute("property", in: tag) ?? attribute("name", in: tag) ?? "").lowercased()
            guard let content = attribute("content", in: tag) else { continue }
            switch key {
            case "og:image", "twitter:image":
                if openGraphImage == nil { openGraphImage = resolve(content, against: baseURL) }
            case "theme-color":
                themeColor = content
            case "apple-mobile-web-app-title", "application-name":
                // Only used if there's no <title>; recorded below via `title`.
                break
            default:
                break
            }
        }
        if let openGraphImage {
            candidates.append(IconCandidate(url: openGraphImage, source: .openGraphImage,
                                            declaredEdge: nil, mimeType: nil))
        }

        return PageMetadata(title: title(in: head) ?? applicationName(in: head),
                            manifestURL: manifestURL,
                            candidates: candidates,
                            themeColor: themeColor)
    }

    /// The `<title>` text, whitespace-collapsed.
    static func title(in html: String) -> String? {
        guard let open = html.range(of: "<title", options: [.caseInsensitive]),
              let gt = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</title", options: [.caseInsensitive],
                                     range: gt.upperBound..<html.endIndex)
        else { return nil }
        let raw = String(html[gt.upperBound..<close.lowerBound])
        let collapsed = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let decoded = decodingEntities(collapsed).trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }

    /// `<meta name="application-name">` / `apple-mobile-web-app-title`, the names a
    /// site gives itself when installed.
    static func applicationName(in html: String) -> String? {
        for tag in tags(named: "meta", in: html) {
            let key = (attribute("name", in: tag) ?? "").lowercased()
            guard key == "application-name" || key == "apple-mobile-web-app-title",
                  let content = attribute("content", in: tag)?
                      .trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty else { continue }
            return decodingEntities(content)
        }
        return nil
    }

    // MARK: Web app manifest

    /// The subset of a web app manifest worth reading.
    ///
    /// Hand-decoded rather than `Codable`, because manifests in the wild break the
    /// spec constantly — `sizes` as a number, `icons` as an object, missing `src` —
    /// and one bad entry must not lose the good ones.
    struct Manifest: Equatable {
        var name: String?
        var shortName: String?
        var themeColor: String?
        var backgroundColor: String?
        var candidates: [IconCandidate]
    }

    static func parseManifest(_ data: Data, manifestURL: URL) -> Manifest? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any] else { return nil }

        var candidates: [IconCandidate] = []
        if let icons = root["icons"] as? [[String: Any]] {
            for icon in icons {
                guard let src = icon["src"] as? String,
                      let url = resolve(src, against: manifestURL) else { continue }
                // `purpose: monochrome` is a mask, not artwork — it renders as a
                // solid silhouette and would make a black square of an app icon.
                let purpose = (icon["purpose"] as? String ?? "").lowercased()
                if purpose.split(whereSeparator: \.isWhitespace).contains("monochrome") { continue }
                candidates.append(IconCandidate(url: url,
                                                source: .webAppManifest,
                                                declaredEdge: largestEdge(in: sizesString(icon["sizes"])),
                                                mimeType: icon["type"] as? String))
            }
        }

        return Manifest(name: (root["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                        shortName: (root["short_name"] as? String)?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                        themeColor: root["theme_color"] as? String,
                        backgroundColor: root["background_color"] as? String,
                        candidates: candidates)
    }

    /// Manifests sometimes give `sizes` as a number (`512`) rather than the spec's
    /// string (`"512x512"`).
    static func sizesString(_ raw: Any?) -> String? {
        if let string = raw as? String { return string }
        if let number = raw as? NSNumber { return "\(number.intValue)x\(number.intValue)" }
        return nil
    }

    // MARK: Attribute scanning

    /// The raw text of every `<name …>` tag in `html`.
    ///
    /// Splits on `<` and keeps runs that start with the tag name followed by a
    /// delimiter, which is enough for the self-closing, unquoted and
    /// attribute-heavy shapes real pages use.
    static func tags(named name: String, in html: String) -> [String] {
        var results: [String] = []
        let lowerName = name.lowercased()
        for piece in html.split(separator: "<", omittingEmptySubsequences: true) {
            let text = String(piece)
            let lower = text.lowercased()
            guard lower.hasPrefix(lowerName) else { continue }
            // Require a delimiter after the name so `<linkedin-widget>` isn't a
            // `<link>`.
            let afterName = text.index(text.startIndex, offsetBy: lowerName.count)
            if afterName < text.endIndex {
                let next = text[afterName]
                guard next.isWhitespace || next == ">" || next == "/" else { continue }
            }
            // Trim at the tag's own `>` so a tag never swallows the markup after it.
            if let close = text.firstIndex(of: ">") {
                results.append(String(text[text.startIndex..<close]))
            } else {
                results.append(text)
            }
        }
        return results
    }

    /// The value of `name` in a tag's text, handling `"…"`, `'…'` and bare values.
    ///
    /// Scans a `[Character]` of the original text and lowercases one character at a
    /// time, rather than searching a lowercased *copy*: lowercasing can change a
    /// string's length (`İ` becomes two scalars), and indices taken from the copy
    /// would then read the wrong part of the original.
    static func attribute(_ name: String, in tag: String) -> String? {
        let characters = Array(tag)
        let wanted = Array(name.lowercased())
        guard !wanted.isEmpty, characters.count > wanted.count else { return nil }

        var index = 0
        while index + wanted.count <= characters.count {
            // A whole attribute name: at the start of the tag text or preceded by
            // whitespace, so `data-rel=` never matches `rel`.
            let precededProperly = index == 0 || characters[index - 1].isWhitespace
            let matches = precededProperly && (0..<wanted.count).allSatisfy {
                // Compare as `String`: `Character.lowercased()` can yield more than
                // one scalar, and building a `Character` from that would trap.
                characters[index + $0].lowercased() == String(wanted[$0])
            }
            guard matches else { index += 1; continue }

            var cursor = index + wanted.count
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count, characters[cursor] == "=" else { index += 1; continue }
            cursor += 1
            while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
            guard cursor < characters.count else { return nil }

            let quote = characters[cursor]
            if quote == "\"" || quote == "'" {
                cursor += 1
                var end = cursor
                // An unterminated quote (malformed markup) takes the rest of the tag.
                while end < characters.count, characters[end] != quote { end += 1 }
                let value = String(characters[cursor..<end])
                return value.isEmpty ? nil : decodingEntities(value)
            }
            var end = cursor
            while end < characters.count, !characters[end].isWhitespace { end += 1 }
            let value = String(characters[cursor..<end])
            return value.isEmpty ? nil : decodingEntities(value)
        }
        return nil
    }

    /// The biggest square edge in a `sizes` attribute (`"32x32 16x16"`, `"180x180"`),
    /// or `nil` for `any`/absent/unparseable.
    static func largestEdge(in sizes: String?) -> Int? {
        guard let sizes, !sizes.isEmpty else { return nil }
        var best: Int?
        for token in sizes.lowercased().split(whereSeparator: \.isWhitespace) {
            guard token != "any" else { continue }
            let parts = token.split(separator: "x")
            let edges = parts.compactMap { Int($0) }
            guard !edges.isEmpty else { continue }
            // Non-square entries are ranked by their smaller edge: what matters for an
            // icon is how much of a square it can fill.
            let edge = edges.min() ?? 0
            if edge > (best ?? 0) { best = edge }
        }
        return best
    }

    /// Resolves a possibly-relative href, rejecting anything that isn't `http(s)`
    /// or a `data:` image.
    static func resolve(_ href: String, against base: URL) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let url = URL(string: trimmed, relativeTo: base)?.absoluteURL else { return nil }
        let scheme = (url.scheme ?? "").lowercased()
        // `data:` is allowed — plenty of sites inline a small favicon that way — but
        // `javascript:` and friends are not.
        guard scheme == "http" || scheme == "https" || scheme == "data" else { return nil }
        return url
    }

    /// Decodes the handful of entities that actually show up in these attributes.
    ///
    /// A full entity table would be overkill for href and title values; `&amp;` in a
    /// query string is the one that matters, and getting it wrong breaks the fetch.
    static func decodingEntities(_ raw: String) -> String {
        guard raw.contains("&") else { return raw }
        var result = raw
        for (entity, replacement) in [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"),
            ("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ] {
            result = result.replacingOccurrences(of: entity, with: replacement,
                                                 options: [.caseInsensitive])
        }
        return result
    }
}

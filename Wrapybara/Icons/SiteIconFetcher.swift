import AppKit

/// Finds a site's best artwork and turns it into an app icon.
///
/// The walk is: fetch the page → read its `<link>`s and its web app manifest →
/// rank the candidates → download them best-first until one decodes to something
/// big enough → compose it onto a macOS plate. If none of that works, the caller
/// falls back to a monogram, which is why nothing here throws for "no icon found".
///
/// Every request is capped in size and time, and nothing fetched is ever executed:
/// `SiteMarkupParser` reads the markup as text rather than loading it into a web
/// view.
struct SiteIconFetcher {

    var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.httpAdditionalHeaders = ["Accept": "text/html,application/xhtml+xml,*/*"]
        return URLSession(configuration: configuration)
    }()

    /// Cap on any single response. A page's `<head>` is a few kilobytes; this is
    /// generous for markup and still refuses to buffer a video someone pointed a
    /// `rel=icon` at.
    var maximumResponseBytes = 4 * 1024 * 1024
    /// The smallest artwork worth composing. Below this a monogram looks better than
    /// a blurred favicon scaled 32× — which is exactly the artefact that makes
    /// wrapper apps look cheap.
    var minimumUsableEdge = 48
    /// How many ranked candidates to try before giving up.
    var maximumAttempts = 6

    // MARK: Result

    struct Outcome {
        /// The composed 1024×1024 icon, ready for `IcnsWriter`.
        var icon: NSImage
        /// The winning artwork *before* composition, so the builder can keep it on
        /// disk and recompose when the plate is restyled. `nil` on the fallback.
        var artwork: NSImage?
        /// Where the winning artwork came from, for `WrapIcon.sourceURL`.
        var sourceURL: URL?
        /// The site's own name, if it advertised one better than the URL guess.
        var suggestedName: String?
        /// The site's `theme_color` / `<meta name="theme-color">`, used as the plate
        /// tint so the icon picks up the site's own colour.
        var themeColorHex: String?
        /// True when this is the monogram fallback rather than the site's artwork.
        var isFallback: Bool
    }

    // MARK: Fetch

    /// Everything discoverable about `url`, without downloading any artwork.
    /// Split out so the "new wrap" sheet can show a name and an icon preview before
    /// the user commits.
    func discover(at url: URL) async -> (metadata: SiteMarkupParser.PageMetadata?,
                                         manifest: SiteMarkupParser.Manifest?) {
        guard let html = await fetchText(url) else { return (nil, nil) }
        let metadata = SiteMarkupParser.parse(html: html, baseURL: url)

        var manifest: SiteMarkupParser.Manifest?
        if let manifestURL = metadata.manifestURL,
           let data = await fetchData(manifestURL) {
            manifest = SiteMarkupParser.parseManifest(data, manifestURL: manifestURL)
        }
        return (metadata, manifest)
    }

    /// The best icon for `url`, or the monogram fallback.
    ///
    /// - Parameter fallbackName: used for the monogram's letters and tint.
    /// - Parameter plate: a plate the user already chose for this wrap. When `nil`
    ///   the plate is derived from the site's `theme-color`, falling back to the
    ///   name-hash tint — an explicit choice always survives a re-fetch.
    func icon(for url: URL, fallbackName: String, style: IconComposer.Style = .plate,
              plate: IconPlate? = nil) async -> Outcome {
        let (metadata, manifest) = await discover(at: url)

        var candidates = (metadata?.candidates ?? []) + (manifest?.candidates ?? [])
        // `/favicon.ico` is always worth a try — plenty of sites serve one and
        // advertise nothing.
        if let root = URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL {
            candidates.append(IconCandidate(url: root, source: .rootFavicon,
                                            declaredEdge: nil, mimeType: nil))
        }

        let siteName = manifest?.name ?? manifest?.shortName ?? metadata?.title
        let themeColor = manifest?.themeColor ?? metadata?.themeColor
        let resolvedPlate = plate ?? IconPlate(colorHex:
            BoostCSSGenerator.sanitizedColor(themeColor) ?? WrapIcon.tintHex(for: fallbackName))

        for candidate in IconCandidate.ranked(candidates).prefix(maximumAttempts) {
            guard let data = await fetchData(candidate.url),
                  let image = NSImage(data: data), image.isValid else { continue }
            let edge = Int(max(image.size.width, image.size.height))
            // Trust the pixels, not the `sizes` attribute — sites lie about it.
            guard edge >= minimumUsableEdge else { continue }

            return Outcome(icon: IconComposer.compose(artwork: image, style: style,
                                                      plate: resolvedPlate),
                           artwork: image,
                           sourceURL: candidate.url,
                           suggestedName: Self.cleanedName(siteName),
                           themeColorHex: themeColor,
                           isFallback: false)
        }

        return Outcome(icon: IconComposer.monogram(WrapIcon.initials(for: fallbackName),
                                                   plate: resolvedPlate),
                       artwork: nil,
                       sourceURL: nil,
                       suggestedName: Self.cleanedName(siteName),
                       themeColorHex: themeColor,
                       isFallback: true)
    }

    /// Re-downloads one specific artwork URL — the "Refresh Icon" path, where the
    /// candidate is already known and there's no reason to crawl again.
    func icon(fromArtworkAt url: URL, fallbackName: String,
              style: IconComposer.Style = .plate, plate: IconPlate? = nil) async -> NSImage? {
        guard let data = await fetchData(url), let image = NSImage(data: data), image.isValid else {
            return nil
        }
        let resolvedPlate = plate ?? IconPlate(colorHex: WrapIcon.tintHex(for: fallbackName))
        return IconComposer.compose(artwork: image, style: style, plate: resolvedPlate)
    }

    // MARK: Transport

    private func fetchText(_ url: URL) async -> String? {
        guard let data = await fetchData(url) else { return nil }
        // Try UTF-8, then the Latin-1 fallback that can't fail. Charset sniffing from
        // a `<meta>` tag isn't worth it: the attributes this needs are ASCII either
        // way, and a mis-decoded page body doesn't change them.
        return ProcessRunner.text(from: data)
    }

    private func fetchData(_ url: URL) async -> Data? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "data" {
            // `NSImage(data:)` can't take a `data:` URL, so decode it here. Only the
            // base64 form is handled; percent-encoded `data:` icons are vanishingly
            // rare.
            return Self.dataURLPayload(url)
        }
        guard scheme == "http" || scheme == "https" else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            guard data.count <= maximumResponseBytes else { return nil }
            return data
        } catch {
            return nil
        }
    }

    /// The bytes of a `data:…;base64,…` URL.
    static func dataURLPayload(_ url: URL) -> Data? {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ","),
              text[text.startIndex..<comma].lowercased().contains(";base64") else { return nil }
        let payload = String(text[text.index(after: comma)...])
        return Data(base64Encoded: payload, options: [.ignoreUnknownCharacters])
    }

    /// A plain Safari `User-Agent`.
    ///
    /// Some sites serve a stub page (or a 403) to unrecognised clients, and a
    /// wrapper that can't find an icon because it announced itself honestly is worse
    /// than one that looks like the browser the user would otherwise have used.
    private var userAgent: String { WrapBehavior.desktopSafariUserAgent }

    /// Trims a page title down to something usable as an app name.
    ///
    /// Titles are full of separators and taglines — `Proton Mail — Encrypted email`.
    /// Everything from the first separator on is dropped.
    static func cleanedName(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let separators = [" — ", " – ", " | ", " · ", " :: ", " - "]
        var name = raw
        for separator in separators {
            if let range = name.range(of: separator) {
                name = String(name[name.startIndex..<range.lowerBound])
            }
        }
        name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 40 else { return nil }
        return name
    }
}

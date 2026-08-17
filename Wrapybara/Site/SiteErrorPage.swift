import AppKit

/// Builds the page a site app shows when a navigation fails.
///
/// A wrap launched offline otherwise shows a blank white window with an NSLog —
/// the single most user-visible gap in the runtime. This is Safari's answer,
/// scaled to what a wrap can honestly say: what went wrong, where it was going,
/// and a **Try Again** that re-issues the navigation.
///
/// Pure string building, so the whole thing is unit-tested without a web view —
/// including the escaping, because a wrap's name and a URL are both attacker- or
/// typo-shaped strings being interpolated into markup.
enum SiteErrorPage {

    /// Whether a navigation failure should replace the page with an error page.
    ///
    /// Only URL-loading errors are failures the user can act on. Anything from
    /// WebKit's own domain — notably "frame load interrupted", which is what a
    /// navigation that turned into a *download* looks like from here — must not
    /// clobber a page. Cancellations are filtered even earlier (they're how every
    /// `.cancel` policy decision arrives), but the check is repeated here so this
    /// stays true if the call sites change.
    static func shouldShow(for error: Error) -> Bool {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else { return false }
        return nsError.code != NSURLErrorCancelled
    }

    /// The URL a navigation failure actually happened at.
    ///
    /// Read off the error first: WebKit's failures carry the *post-redirect*
    /// destination (`A → 301 → B` failing at B reports B), while the URL the
    /// navigation was allowed for is the pre-redirect one. Naming — and retrying —
    /// A would blame the wrong address and fail again on every Try Again.
    static func failingURL(for error: Error, fallbacks: [URL?]) -> URL? {
        let userInfo = (error as NSError).userInfo
        if let url = userInfo[NSURLErrorFailingURLErrorKey] as? URL { return url }
        if let string = userInfo[NSURLErrorFailingURLStringErrorKey] as? String,
           let url = URL(string: string) { return url }
        return fallbacks.lazy.compactMap { $0 }.first
    }

    /// White or near-black, whichever reads on `hex`. The wrap's tint can be any
    /// colour, and a pale tint behind white text makes the one button that matters
    /// illegible.
    static func readableTextColor(onHex hex: String) -> String {
        guard let color = NSColor(hex: hex)?.usingColorSpace(.sRGB) else { return "#ffffff" }
        let luminance = 0.299 * color.redComponent
            + 0.587 * color.greenComponent
            + 0.114 * color.blueComponent
        return luminance > 0.7 ? "#1d1d1f" : "#ffffff"
    }

    /// The HTML for the error page.
    ///
    /// - Parameters:
    ///   - wrapName: shown in the headline, so the page reads as the app's own.
    ///   - failedURL: the address that failed; the Try Again link's target.
    ///   - error: its `localizedDescription` is the detail line — Foundation's
    ///     wording for `NSURLErrorDomain` ("A server with the specified hostname
    ///     could not be found.") is already the human version.
    ///   - tintHex: the wrap's icon tint, reused as the button accent so the page
    ///     looks like it belongs to the app it failed in.
    static func html(wrapName: String, failedURL: URL, error: Error, tintHex: String) -> String {
        let accent = BoostCSSGenerator.sanitizedColor(tintHex)
            ?? BoostCSSGenerator.sanitizedColor(WrapIcon.defaultTintHex)
            ?? "#8b5a2b"
        let accentText = readableTextColor(onHex: accent)
        let name = htmlEscaped(wrapName)
        let description = htmlEscaped(error.localizedDescription)
        let href = htmlEscaped(failedURL.absoluteString)
        let displayURL = htmlEscaped(URLNormalizer.displayString(for: failedURL, maxLength: 80))

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <title>Page unavailable</title>
        <style>
          :root {
            --background: #ffffff;
            --text: #1d1d1f;
            --muted: #6e6e73;
          }
          @media (prefers-color-scheme: dark) {
            :root {
              --background: #1c1c1e;
              --text: #f2f2f7;
              --muted: #98989d;
            }
          }
          html, body { height: 100%; }
          body {
            margin: 0;
            background: var(--background);
            color: var(--text);
            font-family: -apple-system, BlinkMacSystemFont, "SF Pro Text",
                         "Helvetica Neue", sans-serif;
            display: flex;
            align-items: center;
            justify-content: center;
          }
          .card { max-width: 420px; padding: 40px 24px; text-align: center; }
          .glyph {
            width: 52px; height: 52px; margin: 0 auto 20px;
            border: 2px solid var(--muted); border-radius: 50%;
            color: var(--muted); font-size: 26px; font-weight: 600;
            display: flex; align-items: center; justify-content: center;
          }
          h1 { font-size: 21px; font-weight: 600; margin: 0 0 10px; }
          p.detail { color: var(--muted); font-size: 14px; line-height: 1.5; margin: 0 0 6px; }
          p.address {
            color: var(--muted); font-size: 12px; margin: 0 0 26px;
            font-family: ui-monospace, SFMono-Regular, Menlo, monospace;
            overflow-wrap: anywhere;
          }
          a.button {
            display: inline-block; padding: 7px 22px; border-radius: 7px;
            background: \(accent); color: \(accentText); font-size: 14px; font-weight: 500;
            text-decoration: none;
          }
          a.button:active { filter: brightness(0.9); }
        </style>
        </head>
        <body>
          <div class="card">
            <div class="glyph">!</div>
            <h1>\(name) couldn't open the page</h1>
            <p class="detail">\(description)</p>
            <p class="address">\(displayURL)</p>
            <a class="button" href="\(href)">Try Again</a>
          </div>
        </body>
        </html>
        """
    }

    /// Escapes the five characters that matter when interpolating into markup.
    ///
    /// Both the text nodes and the `href` attribute are double-quoted in the
    /// template, so `&`, `<`, `>` and `"` all have to go; `'` comes along for
    /// completeness.
    static func htmlEscaped(_ raw: String) -> String {
        var result = raw
        result = result.replacingOccurrences(of: "&", with: "&amp;")
        result = result.replacingOccurrences(of: "<", with: "&lt;")
        result = result.replacingOccurrences(of: ">", with: "&gt;")
        result = result.replacingOccurrences(of: "\"", with: "&quot;")
        result = result.replacingOccurrences(of: "'", with: "&#39;")
        return result
    }
}

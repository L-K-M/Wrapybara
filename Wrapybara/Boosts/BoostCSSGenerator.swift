import Foundation

/// Turns boosts into CSS.
///
/// Pure `Foundation` only, and deterministic: the same boost always produces
/// byte-identical output, which is what makes `BoostCSSGeneratorTests` able to
/// assert on the stylesheet instead of on a screenshot.
///
/// **On honesty:** restyling an arbitrary site from the outside is heuristic. Zen
/// can do color work inside the engine's style resolution; a `WKWebView` embedder
/// cannot, so this is a stylesheet with `!important` on it. The generator's job is
/// to make that stylesheet as well-behaved as possible — never emit a rule for a
/// knob the user hasn't moved, keep the reach of the aggressive options explicit,
/// and let the user's own CSS win by putting it last.
enum BoostCSSGenerator {

    // MARK: Entry points

    /// The stylesheet for one boost: theme, then zapped elements, then the user's
    /// own CSS last so it can override everything above it.
    static func stylesheet(for boost: Boost) -> String {
        var blocks: [String] = []
        if !boost.theme.isNeutral {
            let theme = themeCSS(boost.theme)
            if !theme.isEmpty { blocks.append(theme) }
        }
        let zap = zapCSS(boost.zapSelectors)
        if !zap.isEmpty { blocks.append(zap) }
        let custom = boost.css.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { blocks.append(custom) }

        guard !blocks.isEmpty else { return "" }
        return "/* Wrapybara boost: \(commentSafe(boost.name)) */\n" + blocks.joined(separator: "\n\n")
    }

    /// The combined stylesheet for an ordered boost list. Later boosts win, which is
    /// why `WrapLibrary.resolvedBoosts(for:)` puts shared boosts last.
    static func stylesheet(for boosts: [Boost]) -> String {
        boosts
            .map(stylesheet(for:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    // MARK: Zap

    /// `display: none` for every zapped selector, as one rule.
    ///
    /// Selectors are checked, not escaped: a selector containing a brace or a
    /// comment marker would break out of the rule and change the meaning of
    /// everything after it, so those are dropped rather than sanitized into
    /// something that no longer selects what the user picked.
    static func zapCSS(_ selectors: [String]) -> String {
        let usable = selectors
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && isSafeSelector($0) }
        guard !usable.isEmpty else { return "" }
        let list = usable.joined(separator: ",\n")
        return "/* zapped */\n\(list) {\n  display: none !important;\n}"
    }

    /// Rejects a selector that could terminate the rule it's placed in.
    static func isSafeSelector(_ selector: String) -> Bool {
        guard !selector.contains("{"), !selector.contains("}"),
              !selector.contains(";"), !selector.contains("/*"), !selector.contains("*/"),
              !selector.contains("\n"), !selector.contains("\r"),
              !selector.contains("<") else { return false }
        // A trailing comma would swallow whatever selector follows it in the list.
        return !selector.hasSuffix(",") && !selector.hasPrefix(",")
    }

    // MARK: Theme

    static func themeCSS(_ theme: BoostTheme) -> String {
        var rules: [String] = []

        // 1. Root filter. One `filter` declaration carries every image adjustment.
        if let filter = filterValue(theme) {
            rules.append("html {\n  filter: \(filter);\n}")
            // Undo the inversion on media so photographs don't come out negative.
            // Applying the same invert twice cancels it; the paired hue-rotate keeps
            // colors where they started. This is the standard trick and it is an
            // approximation — a filtered ancestor still composites its descendants.
            if theme.invert > 0, theme.preservesMediaWhenInverted {
                let counter = "invert(\(number(theme.invert))) hue-rotate(180deg)"
                rules.append("""
                img, video, canvas, picture, iframe, embed, object,
                [style*="background-image"] {
                  filter: \(counter);
                }
                """)
            }
        }

        // 2. Colors.
        if let background = sanitizedColor(theme.backgroundColor) {
            if theme.colorReach == .everything {
                // Clear every element's own background so the root color shows
                // through. `background-color` only — the `background` shorthand
                // would also drop background *images*, and sites draw logos and
                // icons that way.
                rules.append("*:not(svg):not(svg *) {\n  background-color: transparent !important;\n}")
            }
            rules.append("html, body {\n  background-color: \(background) !important;\n}")
        }
        if let text = sanitizedColor(theme.textColor) {
            if theme.colorReach == .everything {
                rules.append("*:not(a):not(svg):not(svg *) {\n  color: \(text) !important;\n}")
            }
            rules.append("html, body {\n  color: \(text) !important;\n}")
        }
        // Links after the blanket text rule, so they survive it.
        if let link = sanitizedColor(theme.linkColor) {
            rules.append("a, a:visited, a:hover {\n  color: \(link) !important;\n}")
        }
        if let accent = sanitizedColor(theme.accentColor) {
            rules.append(":root {\n  accent-color: \(accent) !important;\n}")
        }

        // 3. Type.
        if let family = sanitizedFontStack(theme.fontFamily) {
            // Icon fonts are the reason this isn't just `* { font-family: … }`:
            // sites map private-use glyphs onto a font, and replacing it turns every
            // icon into tofu. Excluding the conventional icon class names and the
            // `<i>` element catches the common frameworks.
            rules.append("""
            body, body *:not(\(Self.iconFontExclusions.joined(separator: "):not("))) {
              font-family: \(family) !important;
            }
            """)
        }
        if let mono = sanitizedFontStack(theme.monospaceFontFamily) {
            rules.append("code, pre, kbd, samp, tt {\n  font-family: \(mono) !important;\n}")
        }
        if theme.fontScale != 1 {
            let percent = number(theme.fontScale * 100)
            rules.append(":root {\n  font-size: \(percent)% !important;\n}")
        }
        if theme.lineHeightScale != 1 {
            rules.append("body {\n  line-height: \(number(theme.lineHeightScale * 1.5)) !important;\n}")
        }
        if let transform = theme.textTransform.cssValue {
            rules.append("body, body * {\n  text-transform: \(transform) !important;\n}")
        }
        if let width = theme.readableWidth, width > 0 {
            rules.append("""
            article, main, [role="main"] {
              max-width: \(number(width))px !important;
              margin-left: auto !important;
              margin-right: auto !important;
            }
            """)
        }

        // 4. Surfaces.
        if let radius = theme.cornerRadius, radius >= 0 {
            rules.append("""
            img, video, canvas, button, input, select, textarea {
              border-radius: \(number(radius))px !important;
            }
            """)
        }
        if theme.hidesImages {
            rules.append("img, picture, video, svg {\n  visibility: hidden !important;\n}")
        }

        return rules.joined(separator: "\n\n")
    }

    /// The `filter` value for a theme's image adjustments, or `nil` when every knob
    /// is at its neutral value.
    ///
    /// Order matters and is fixed: invert first (so brightness/contrast act on the
    /// inverted image the way a reader expects), then hue, then the rest.
    static func filterValue(_ theme: BoostTheme) -> String? {
        var functions: [String] = []
        if theme.invert > 0 { functions.append("invert(\(number(theme.invert)))") }
        if theme.hueRotate != 0 { functions.append("hue-rotate(\(number(theme.hueRotate))deg)") }
        if theme.brightness != 1 { functions.append("brightness(\(number(theme.brightness)))") }
        if theme.contrast != 1 { functions.append("contrast(\(number(theme.contrast)))") }
        if theme.saturation != 1 { functions.append("saturate(\(number(theme.saturation)))") }
        if theme.grayscale > 0 { functions.append("grayscale(\(number(theme.grayscale)))") }
        return functions.isEmpty ? nil : functions.joined(separator: " ")
    }

    /// Class-name fragments and elements excluded from a blanket font override,
    /// because they're how icon fonts are conventionally applied.
    static let iconFontExclusions = [
        "i", "[class*=\"icon\"]", "[class*=\"Icon\"]", "[class*=\"fa-\"]",
        "[class*=\"material-icons\"]", "[class*=\"glyphicon\"]", "code", "pre", "kbd", "samp",
    ]

    // MARK: Value sanitizing

    /// Normalises a `#RGB`/`#RGBA`/`#RRGGBB`/`#RRGGBBAA` string to lowercase
    /// `#rrggbb[aa]`, or returns `nil`.
    ///
    /// Emitting only values that parse keeps a hand-edited or imported config from
    /// putting arbitrary text into a declaration — and keeps a typo from silently
    /// invalidating the rest of the rule it sits in.
    static func sanitizedColor(_ raw: String?) -> String? {
        guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        if value.hasPrefix("#") { value.removeFirst() }
        guard value.allSatisfy(\.isHexDigit) else { return nil }
        switch value.count {
        case 3, 4:
            // Expand the CSS shorthand so the output is one canonical form.
            return "#" + value.map { "\($0)\($0)" }.joined().lowercased()
        case 6, 8:
            return "#" + value.lowercased()
        default:
            return nil
        }
    }

    /// Passes a CSS font stack through, or returns `nil` for empty input.
    ///
    /// Font stacks legitimately contain quotes, commas and spaces, so this can't
    /// escape them — instead it rejects the characters that would end the
    /// declaration or start a comment.
    static func sanitizedFontStack(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        let forbidden: [Character] = ["{", "}", ";", "<", ">", "\n", "\r"]
        guard !value.contains(where: forbidden.contains),
              !value.contains("/*"), !value.contains("*/") else { return nil }
        return value
    }

    /// Neutralises `*/` so a boost name can't close the comment it's written into.
    static func commentSafe(_ raw: String) -> String {
        raw.replacingOccurrences(of: "*/", with: "* /")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    /// Formats a number for CSS without a locale (`%g` would honour one) and
    /// without a trailing `.0`, so output stays byte-stable across machines.
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "0" }
        if value == value.rounded(), abs(value) < 1e15 {
            return String(Int(value.rounded()))
        }
        // Six significant digits is far more than any of these knobs needs, and
        // `%g` with the POSIX locale never emits a comma as the decimal separator.
        return String(format: "%g", locale: nil, value)
    }
}

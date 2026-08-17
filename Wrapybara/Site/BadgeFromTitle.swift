import Foundation

/// Reads an unread count out of a page title so it can go on the Dock icon.
///
/// Web apps have advertised their unread count in `document.title` since long
/// before the Badging API, and most still do — `(3) Inbox`, `Inbox (3)`,
/// `[3] Slack`, `• Notion`. WKWebView exposes no badge API, so this is how a site
/// app gets a Dock badge that matches the tab a browser would show.
///
/// Pure and table-tested: it runs on every `title` change, and a false positive
/// (a badge of "2024" from a page called `Report 2024`) is worse than no badge.
enum BadgeFromTitle {

    /// The badge text for `title`, or `nil` for none.
    ///
    /// - A parenthesised or bracketed leading/trailing number becomes that number.
    /// - `9,999`/`9.999` grouping is understood; `99+` is kept verbatim.
    /// - A bare number anywhere else is ignored — too many page titles contain years,
    ///   versions and prices.
    /// - A leading bullet or asterisk with no number becomes "•", the conventional
    ///   "something happened, no count" marker.
    static func badge(for title: String?) -> String? {
        guard let title, !title.isEmpty else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let count = enclosedCount(in: trimmed) { return count }
        if hasUnreadMarker(trimmed) { return "•" }
        return nil
    }

    /// The numeric badge for `title` as an integer, for callers that want to compare
    /// counts rather than display them. `nil` when there is no count (including when
    /// the badge is the bullet marker or a capped `99+`).
    static func count(for title: String?) -> Int? {
        guard let badge = badge(for: title) else { return nil }
        return Int(badge)
    }

    // MARK: Parsing

    /// Openers paired with their closers, in the order sites actually use them.
    private static let brackets: [(open: Character, close: Character)] = [
        ("(", ")"), ("[", "]"), ("{", "}"),
    ]

    /// A number inside brackets at the very start or very end of the title.
    ///
    /// The two positions are not treated alike, and that asymmetry is the whole
    /// reason this is worth testing. A *leading* `(n)` is the unread-count
    /// convention and essentially never means anything else, so it takes counts up
    /// to six digits. A *trailing* `(n)` is far more often a year, an edition or a
    /// version — `Annual Report (2024)` — so it is capped at three digits (plus the
    /// explicitly-capped `99+` form, which can only be a count). A user with 1,500
    /// unread items whose site puts the number last therefore gets no badge; that's
    /// a deliberate trade against badging every dated page on the web.
    static func enclosedCount(in title: String) -> String? {
        for (open, close) in brackets {
            if title.hasPrefix(String(open)),
               let closeIndex = title.firstIndex(of: close) {
                let inner = String(title[title.index(after: title.startIndex)..<closeIndex])
                if let value = normalizedCount(inner, maximumDigits: 6) { return value }
            }
            if title.hasSuffix(String(close)),
               let openIndex = title.lastIndex(of: open) {
                let innerStart = title.index(after: openIndex)
                let innerEnd = title.index(before: title.endIndex)
                if innerStart <= innerEnd {
                    let inner = String(title[innerStart..<innerEnd])
                    if let value = normalizedCount(inner, maximumDigits: 3) { return value }
                }
            }
        }
        return nil
    }

    /// Normalises the text between brackets into a badge, or rejects it.
    ///
    /// Accepts `3`, `1,234`, `1.234`, `1 234` (thin/regular space grouping) and the
    /// capped forms `99+` / `9999+`. Rejects everything else, including the empty
    /// string, so `(beta)` and `(2024–2025)` don't become badges.
    ///
    /// `maximumDigits` bounds the plain (uncapped) form only — see `enclosedCount`
    /// for why the two bracket positions pass different limits.
    static func normalizedCount(_ raw: String, maximumDigits: Int = 6) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8 else { return nil }

        let isCapped = trimmed.hasSuffix("+")
        let digitsPart = isCapped ? String(trimmed.dropLast()) : trimmed

        // Strip grouping separators, then require what's left to be all digits.
        let stripped = digitsPart.filter { !groupingSeparators.contains($0) }
        // The explicitly-capped `99+` form is unambiguous, so it isn't subject to
        // the caller's digit limit — only to the hard six-digit ceiling.
        let limit = isCapped ? 6 : max(1, min(6, maximumDigits))
        guard !stripped.isEmpty, stripped.allSatisfy(\.isNumber), stripped.count <= limit else {
            return nil
        }
        // Reject grouping that wasn't grouping: `1.2.3` is a version, `12,5` a price.
        if stripped.count != digitsPart.count {
            let separatorCount = digitsPart.count - stripped.count
            guard isPlausibleGrouping(digitsPart, separatorCount: separatorCount) else { return nil }
        }
        guard let value = Int(stripped) else { return nil }
        // A leading zero means it wasn't a count (`(007)`), and zero itself means
        // "nothing unread" — the badge should come off, not read "0".
        if value == 0 { return nil }
        if stripped.count > 1, stripped.hasPrefix("0") { return nil }
        return isCapped ? stripped + "+" : stripped
    }

    private static let groupingSeparators: Set<Character> = [",", ".", " ", "\u{2009}", "\u{202F}", "\u{00A0}"]

    /// Whether the separators in `text` sit where thousands separators sit: every
    /// group after the first exactly three digits long.
    static func isPlausibleGrouping(_ text: String, separatorCount: Int) -> Bool {
        guard separatorCount > 0 else { return true }
        let groups = text.split(whereSeparator: { groupingSeparators.contains($0) })
        guard groups.count == separatorCount + 1, let first = groups.first else { return false }
        guard first.count >= 1, first.count <= 3 else { return false }
        return groups.dropFirst().allSatisfy { $0.count == 3 }
    }

    /// A leading "something is unread" marker with no number attached.
    static func hasUnreadMarker(_ title: String) -> Bool {
        guard let first = title.first else { return false }
        let markers: Set<Character> = ["•", "●", "*", "‣", "◦", "▲"]
        guard markers.contains(first) else { return false }
        // Require something after the marker, so a title that *is* a bullet isn't one.
        return title.dropFirst().contains(where: { !$0.isWhitespace })
    }
}

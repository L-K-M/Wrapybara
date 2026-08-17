import Foundation

/// One site customization: knobs (`theme`), hidden elements (`zapSelectors`), and
/// the two escape hatches (`css`, `javaScript`).
///
/// A boost is a value type with no reference to the page it will be applied to;
/// `BoostMatcher` decides *whether* it applies and `BoostCSSGenerator` /
/// `BoostInjector` decide *how*. That split is what lets the whole feature be
/// unit-tested without a `WKWebView`.
struct Boost: Codable, Identifiable, Equatable {

    /// When a boost's JavaScript runs.
    enum InjectionTime: String, Codable, CaseIterable, Identifiable {
        /// Before the document's own scripts — for shimming or blocking things.
        case documentStart
        /// After the DOM is parsed — the usual choice for DOM surgery.
        case documentEnd

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .documentStart: return "Before page scripts"
            case .documentEnd: return "After the page loads"
            }
        }
    }

    var id: UUID
    var name: String
    var isEnabled: Bool
    var match: BoostMatch
    var theme: BoostTheme
    /// CSS selectors to hide. Kept as a list rather than folded into `css` so the
    /// element picker can add and remove them one at a time, and so un-zapping a
    /// single element doesn't mean re-parsing a stylesheet.
    var zapSelectors: [String]
    var css: String
    var javaScript: String
    var javaScriptInjectionTime: InjectionTime
    /// Gate on running `javaScript`.
    ///
    /// A boost is a shareable file, and its JavaScript runs in the page's origin
    /// with access to the session that app is signed into. Boosts *you* write are
    /// trusted on save; boosts that arrive by import are not, and their script
    /// stays inert until you read it and say so. `css` needs no such gate — CSS
    /// can restyle a page but cannot read it.
    var isJavaScriptTrusted: Bool
    var notes: String
    var createdAt: Date
    var updatedAt: Date

    init(id: UUID = UUID(),
         name: String = "New Boost",
         isEnabled: Bool = true,
         match: BoostMatch = .everywhere,
         theme: BoostTheme = .neutral,
         zapSelectors: [String] = [],
         css: String = "",
         javaScript: String = "",
         javaScriptInjectionTime: InjectionTime = .documentEnd,
         isJavaScriptTrusted: Bool = true,
         notes: String = "",
         createdAt: Date = Date(),
         updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.match = match
        self.theme = theme
        self.zapSelectors = zapSelectors
        self.css = css
        self.javaScript = javaScript
        self.javaScriptInjectionTime = javaScriptInjectionTime
        self.isJavaScriptTrusted = isJavaScriptTrusted
        self.notes = notes
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // MARK: Derived

    /// Whether the boost has any JavaScript that is actually allowed to run.
    var hasRunnableJavaScript: Bool {
        isJavaScriptTrusted && !javaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the boost has JavaScript that is being held back pending review.
    var hasUntrustedJavaScript: Bool {
        !isJavaScriptTrusted && !javaScript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when the boost would do nothing at all if applied. An empty boost is
    /// legal (you just made it and haven't filled it in), but it shouldn't cost a
    /// `<style>` element or a user script.
    var isEmpty: Bool {
        theme.isNeutral
            && zapSelectors.isEmpty
            && css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !hasRunnableJavaScript
    }

    /// A one-line description of what this boost carries, for the library list.
    var contentsSummary: String {
        var parts: [String] = []
        if !theme.isNeutral { parts.append("theme") }
        if !zapSelectors.isEmpty {
            parts.append("\(zapSelectors.count) zapped element\(zapSelectors.count == 1 ? "" : "s")")
        }
        if !css.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { parts.append("CSS") }
        if hasRunnableJavaScript { parts.append("JavaScript") }
        if hasUntrustedJavaScript { parts.append("JavaScript (not trusted)") }
        return parts.isEmpty ? "Empty" : parts.joined(separator: " · ")
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, name, isEnabled, match, theme, zapSelectors, css
        case javaScript, javaScriptInjectionTime, isJavaScriptTrusted
        case notes, createdAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `id` is the one field with no sensible default: two boosts sharing a
        // generated id would collide in the editor's selection, so a file missing it
        // gets a fresh one.
        self.id = c.value(.id, or: UUID())
        self.name = c.value(.name, or: "Boost")
        self.isEnabled = c.value(.isEnabled, or: true)
        self.match = c.value(.match, or: BoostMatch.everywhere)
        self.theme = c.value(.theme, or: BoostTheme.neutral)
        self.zapSelectors = c.value(.zapSelectors, or: [String]())
        self.css = c.value(.css, or: "")
        self.javaScript = c.value(.javaScript, or: "")
        self.javaScriptInjectionTime = c.value(.javaScriptInjectionTime, or: InjectionTime.documentEnd)
        // Default *false* on decode, unlike the memberwise initializer's `true`.
        // A file that predates the flag, or one hand-edited to drop it, must not
        // silently gain permission to run its script.
        self.isJavaScriptTrusted = c.value(.isJavaScriptTrusted, or: false)
        self.notes = c.value(.notes, or: "")
        self.createdAt = c.value(.createdAt, or: Date())
        self.updatedAt = c.value(.updatedAt, or: Date())
    }
}

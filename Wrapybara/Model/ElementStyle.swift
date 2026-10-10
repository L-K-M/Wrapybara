import Foundation

/// CSS declarations applied to the elements one selector matches: the element
/// picker's other half. Zap hides what you pick; this restyles it.
///
/// Kept as a selector and a bare declaration list rather than folded into
/// `Boost.css` so the picker can add one at a time and the editor can show each
/// picked element beside its own styles.
struct ElementStyle: Codable, Identifiable, Equatable {

    var id: UUID
    var selector: String
    /// The body of the rule, without braces: `color: #c00; font-weight: 600`.
    /// `BoostCSSGenerator` marks each declaration `!important` so it wins over
    /// the site's own, usually more specific, rules.
    var declarations: String

    init(id: UUID = UUID(), selector: String, declarations: String = "") {
        self.id = id
        self.selector = selector
        self.declarations = declarations
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, selector, declarations
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = c.value(.id, or: UUID())
        self.selector = c.value(.selector, or: "")
        self.declarations = c.value(.declarations, or: "")
    }
}

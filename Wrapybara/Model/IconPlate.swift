import AppKit
import Foundation

/// How the squircle behind a wrap's artwork is painted: a colour, and optionally
/// one of the classic desktop tiles instead of the smooth gradient.
///
/// Stored on `WrapIcon` as an optional. `nil` means *automatic* — the behaviour
/// from before plates were editable: a gradient derived from the wrap's `tintHex`
/// (itself the site's `theme-color` when it offers one). Keeping "automatic" as
/// the absence of a value rather than a third case means existing libraries
/// decode unchanged and a re-fetch keeps tracking the site's own colour until
/// the user deliberately picks one.
struct IconPlate: Codable, Equatable {

    /// The plate's base colour, `#RRGGBB`. A pattern draws in two tones of it.
    var colorHex: String
    /// The classic tile to draw, or `nil` for the smooth gradient.
    var pattern: PlatePattern?

    init(colorHex: String = WrapIcon.defaultTintHex, pattern: PlatePattern? = nil) {
        self.colorHex = colorHex
        self.pattern = pattern
    }

    /// What to actually paint for `icon`: the user's choice, or the automatic
    /// gradient in the wrap's tint when no choice has been made.
    static func resolved(for icon: WrapIcon) -> IconPlate {
        icon.plate ?? IconPlate(colorHex: icon.tintHex)
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case colorHex, pattern
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // A colour that isn't a colour costs only this field, not the icon: the
        // plate drops to the default tint rather than carrying a string the
        // composer would have to second-guess at draw time. Wrong *types* are
        // already swallowed by `value(_:or:)`; this catches well-typed junk like
        // `"octarine"`.
        let stored = c.value(.colorHex, or: WrapIcon.defaultTintHex)
        self.colorHex = NSColor(hex: stored) != nil ? stored : WrapIcon.defaultTintHex
        // A pattern name this build doesn't know — from the future, or mistyped
        // by hand — drops to the gradient rather than failing the whole icon.
        self.pattern = c.optional(.pattern)
    }
}

import Foundation

/// The knob-driven half of a boost: colors, type, and image adjustments that
/// `BoostCSSGenerator` turns into a stylesheet. The escape hatches (arbitrary CSS
/// and JavaScript) live on `Boost` itself.
///
/// Every numeric knob is expressed so that **the identity value is the neutral
/// one** — `1.0` for the multiplicative ones, `0` for the additive ones — so an
/// all-defaults theme generates no CSS at all. `BoostCSSGeneratorTests` asserts
/// that, because it's what makes "boost enabled but empty" cost nothing.
struct BoostTheme: Codable, Equatable {

    /// How far the color overrides reach into the page.
    ///
    /// Repainting an arbitrary site from CSS is heuristic by nature; rather than
    /// pretend otherwise, this exposes the trade-off. `.surfaces` is safe and often
    /// not enough; `.everything` is the classic userstyle hammer (clear every
    /// element's background so the root color shows through) and will occasionally
    /// flatten a design that was using background color to convey structure.
    enum ColorReach: String, Codable, CaseIterable, Identifiable {
        /// Only `html` and `body`.
        case surfaces
        /// Every element's background is cleared so the root color shows through.
        case everything

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .surfaces: return "Page background only"
            case .everything: return "Every element"
            }
        }
    }

    enum TextTransform: String, Codable, CaseIterable, Identifiable {
        case none, uppercase, lowercase, capitalize

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .none: return "Unchanged"
            case .uppercase: return "UPPERCASE"
            case .lowercase: return "lowercase"
            case .capitalize: return "Capitalize"
            }
        }

        /// The CSS `text-transform` value, or `nil` for "emit nothing".
        /// Spelled `TextTransform.none` rather than `.none` so it can't be read as
        /// `Optional.none` against the `String?` result type.
        var cssValue: String? { self == TextTransform.none ? nil : rawValue }
    }

    // MARK: Color

    /// `#RRGGBB[AA]`, or `nil` to leave the site's own color alone.
    var backgroundColor: String?
    var textColor: String?
    var linkColor: String?
    /// Substituted for the site's `accent-color` and used for form controls.
    var accentColor: String?
    var colorReach: ColorReach

    // MARK: Type

    /// A CSS font stack (`"Iowan Old Style", Georgia, serif`) or a bare family
    /// name; `nil`/empty leaves the site's fonts alone.
    var fontFamily: String?
    /// Applied to `code`, `pre`, `kbd`, `samp` and `tt` only.
    var monospaceFontFamily: String?
    /// Multiplies the root font size. `1.0` = unchanged.
    var fontScale: Double
    var textTransform: TextTransform
    /// Multiplies `line-height` on `body`. `1.0` = unchanged.
    var lineHeightScale: Double
    /// Caps the width of `article`/`main` and centers it, for readability.
    /// `nil` = unchanged.
    var readableWidth: Double?

    // MARK: Image / filter adjustments

    /// All multiplicative: `1.0` is neutral.
    var brightness: Double
    var contrast: Double
    var saturation: Double
    /// Degrees, `0` neutral.
    var hueRotate: Double
    /// `0`…`1`, `0` neutral.
    var invert: Double
    var grayscale: Double
    /// When inverting, counter-invert images, video and canvas so photographs
    /// don't come out as negatives — the same trick as the system's Smart Invert.
    var preservesMediaWhenInverted: Bool
    /// Rounds the corners of common surfaces (`img`, `button`, `input`, `video`).
    /// `nil` = unchanged.
    var cornerRadius: Double?
    var hidesImages: Bool

    // MARK: Init

    init(backgroundColor: String? = nil,
         textColor: String? = nil,
         linkColor: String? = nil,
         accentColor: String? = nil,
         colorReach: ColorReach = .surfaces,
         fontFamily: String? = nil,
         monospaceFontFamily: String? = nil,
         fontScale: Double = 1,
         textTransform: TextTransform = .none,
         lineHeightScale: Double = 1,
         readableWidth: Double? = nil,
         brightness: Double = 1,
         contrast: Double = 1,
         saturation: Double = 1,
         hueRotate: Double = 0,
         invert: Double = 0,
         grayscale: Double = 0,
         preservesMediaWhenInverted: Bool = true,
         cornerRadius: Double? = nil,
         hidesImages: Bool = false) {
        self.backgroundColor = backgroundColor
        self.textColor = textColor
        self.linkColor = linkColor
        self.accentColor = accentColor
        self.colorReach = colorReach
        self.fontFamily = fontFamily
        self.monospaceFontFamily = monospaceFontFamily
        self.fontScale = fontScale
        self.textTransform = textTransform
        self.lineHeightScale = lineHeightScale
        self.readableWidth = readableWidth
        self.brightness = brightness
        self.contrast = contrast
        self.saturation = saturation
        self.hueRotate = hueRotate
        self.invert = invert
        self.grayscale = grayscale
        self.preservesMediaWhenInverted = preservesMediaWhenInverted
        self.cornerRadius = cornerRadius
        self.hidesImages = hidesImages
    }

    /// A theme that changes nothing.
    static let neutral = BoostTheme()

    /// True when this theme would generate no CSS — used to keep an untouched
    /// theme from adding an empty `<style>` element to every page.
    var isNeutral: Bool { self == .neutral }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case backgroundColor, textColor, linkColor, accentColor, colorReach
        case fontFamily, monospaceFontFamily, fontScale, textTransform
        case lineHeightScale, readableWidth
        case brightness, contrast, saturation, hueRotate, invert, grayscale
        case preservesMediaWhenInverted, cornerRadius, hidesImages
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.backgroundColor = c.optional(.backgroundColor)
        self.textColor = c.optional(.textColor)
        self.linkColor = c.optional(.linkColor)
        self.accentColor = c.optional(.accentColor)
        self.colorReach = c.value(.colorReach, or: ColorReach.surfaces)
        self.fontFamily = c.optional(.fontFamily)
        self.monospaceFontFamily = c.optional(.monospaceFontFamily)
        self.fontScale = c.value(.fontScale, or: 1.0)
        self.textTransform = c.value(.textTransform, or: TextTransform.none)
        self.lineHeightScale = c.value(.lineHeightScale, or: 1.0)
        self.readableWidth = c.optional(.readableWidth)
        self.brightness = c.value(.brightness, or: 1.0)
        self.contrast = c.value(.contrast, or: 1.0)
        self.saturation = c.value(.saturation, or: 1.0)
        self.hueRotate = c.value(.hueRotate, or: 0.0)
        self.invert = c.value(.invert, or: 0.0)
        self.grayscale = c.value(.grayscale, or: 0.0)
        self.preservesMediaWhenInverted = c.value(.preservesMediaWhenInverted, or: true)
        self.cornerRadius = c.optional(.cornerRadius)
        self.hidesImages = c.value(.hidesImages, or: false)
    }
}

import AppKit

/// Builds a macOS-shaped app icon.
///
/// This is one of the places where a wrapper either passes for a native app or
/// doesn't. A site's `apple-touch-icon` is a full-bleed square drawn for an iOS home
/// screen; dropped straight into a Mac app bundle it sits in the Dock as a hard
/// square among rounded plates, at the wrong visual weight, with no margin. So by
/// default the artwork is *composed* onto a macOS-proportioned rounded plate —
/// 824/1024 of the canvas, the same inset Apple's own icons use — instead of being
/// used raw.
///
/// `Style.asIs` is there for the cases where the site already ships something
/// icon-shaped and the user knows better.
enum IconComposer {

    enum Style: String, Codable, CaseIterable, Identifiable {
        /// Compose the artwork onto a rounded plate with macOS margins.
        case plate
        /// Use the artwork as the whole canvas.
        case asIs

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .plate: return "Mac-style plate"
            case .asIs: return "Artwork as-is"
            }
        }
    }

    /// The icon canvas edge, in points. macOS app icons top out at 1024.
    static let canvas: CGFloat = 1024
    /// The plate occupies 824 of 1024 — Apple's macOS app-icon grid.
    static let plateEdge: CGFloat = 824
    /// The plate's corner radius at 1024, matching the system squircle closely
    /// enough that it doesn't read as "a rounded rectangle someone drew".
    static let plateRadius: CGFloat = 185
    /// How much of the plate the site's artwork fills. Leaving a margin is what
    /// stops a logo from looking cramped against the plate edge.
    static let artworkFraction: CGFloat = 0.66

    // MARK: Composition

    /// The finished 1024×1024 icon for `artwork`.
    static func compose(artwork: NSImage, style: Style, plateColor: NSColor) -> NSImage {
        switch style {
        case .asIs:
            return redraw(artwork, edge: canvas)
        case .plate:
            return NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
                drawPlate(color: plateColor)
                let artworkEdge = plateEdge * artworkFraction
                let origin = (canvas - artworkEdge) / 2
                artwork.draw(in: NSRect(x: origin, y: origin, width: artworkEdge, height: artworkEdge),
                             from: .zero, operation: .sourceOver, fraction: 1)
                return true
            }
        }
    }

    /// The monogram fallback: initials on a tinted plate, for a wrap whose site
    /// offered no usable artwork.
    static func monogram(_ letters: String, plateColor: NSColor) -> NSImage {
        NSImage(size: NSSize(width: canvas, height: canvas), flipped: false) { _ in
            drawPlate(color: plateColor)

            let text = letters.isEmpty ? "?" : letters
            // Size the type to the number of glyphs so one letter isn't lost on the
            // plate and three don't run off it.
            let pointSize: CGFloat = text.count >= 2 ? 340 : 460
            let font = NSFont.systemFont(ofSize: pointSize, weight: .semibold)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white.withAlphaComponent(0.95),
                .kern: -pointSize * 0.02,
            ]
            let attributed = NSAttributedString(string: text, attributes: attributes)
            let size = attributed.size()
            // Center on the cap-height box rather than the line box, so the letters
            // sit optically centered instead of low.
            let x = (canvas - size.width) / 2
            let y = (canvas - size.height) / 2 + font.descender / 2
            attributed.draw(at: NSPoint(x: x, y: y))
            return true
        }
    }

    // MARK: Pieces

    /// Fills the plate: a rounded rect with a soft vertical gradient so it doesn't
    /// look like flat colour, plus a hairline top highlight.
    static func drawPlate(color: NSColor) {
        let inset = (canvas - plateEdge) / 2
        let rect = NSRect(x: inset, y: inset, width: plateEdge, height: plateEdge)
        let path = NSBezierPath(roundedRect: rect, xRadius: plateRadius, yRadius: plateRadius)

        let base = color.usingColorSpace(.sRGB) ?? color
        let top = base.blended(withFraction: 0.18, of: .white) ?? base
        let bottom = base.blended(withFraction: 0.12, of: .black) ?? base
        // AppKit's y axis points up, so `angle: -90` runs the gradient top-to-bottom.
        NSGradient(starting: top, ending: bottom)?.draw(in: path, angle: -90)

        NSColor.white.withAlphaComponent(0.10).setStroke()
        path.lineWidth = canvas * 0.006
        path.stroke()
    }

    /// Rasterises `image` into a fresh square image of `edge` points.
    ///
    /// A fetched favicon can arrive as a multi-representation ICO or an SVG-backed
    /// image; drawing it once into a known-size canvas gives everything downstream
    /// one predictable representation to work with.
    static func redraw(_ image: NSImage, edge: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: edge, height: edge), flipped: false) { _ in
            image.draw(in: NSRect(x: 0, y: 0, width: edge, height: edge),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    /// The plate colour for a wrap: its stored tint, or Wrapybara's brown.
    static func plateColor(for icon: WrapIcon) -> NSColor {
        NSColor(hex: icon.tintHex) ?? NSColor(hex: WrapIcon.defaultTintHex) ?? .systemBrown
    }
}

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
                let box = NSRect(x: origin, y: origin, width: artworkEdge, height: artworkEdge)
                artwork.draw(in: aspectFit(size: artwork.size, in: box),
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
    /// one predictable representation to work with. Non-square images are
    /// aspect-fitted and centered, leaving transparent bands where the image
    /// doesn't fill the square — the only caller is `.asIs` artwork composition,
    /// where that's the point; a caller needing edge-to-edge coverage shouldn't
    /// route through here.
    static func redraw(_ image: NSImage, edge: CGFloat) -> NSImage {
        let canvasRect = NSRect(x: 0, y: 0, width: edge, height: edge)
        return NSImage(size: NSSize(width: edge, height: edge), flipped: false) { _ in
            image.draw(in: aspectFit(size: image.size, in: canvasRect),
                       from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }

    /// The largest rect of `size`'s aspect ratio that fits inside `bounds`, centered.
    ///
    /// Artwork is fitted, never stretched: a wide or tall logo squashed into a square
    /// reads far worse than the transparent bands letterboxing leaves. A degenerate
    /// (zero) size falls back to the full bounds — the one stretch path left, since
    /// there is no aspect to preserve.
    static func aspectFit(size: NSSize, in bounds: NSRect) -> NSRect {
        guard size.width > 0, size.height > 0 else { return bounds }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = NSSize(width: size.width * scale, height: size.height * scale)
        // Whole points keep the edges crisp, but round to nearest rather than
        // `.integral`: integral rects only ever grow, and up to ~1 pt of growth per
        // axis is a visible aspect change at the small icns sizes (a 5:1 wordmark
        // fitted into 16×16 wants 16×3, not 16×4).
        let width = max(fitted.width.rounded(), 1)
        let height = max(fitted.height.rounded(), 1)
        return NSRect(x: bounds.minX + ((bounds.width - width) / 2).rounded(),
                      y: bounds.minY + ((bounds.height - height) / 2).rounded(),
                      width: width,
                      height: height)
    }

    /// The plate colour for a wrap: its stored tint, or Wrapybara's brown.
    static func plateColor(for icon: WrapIcon) -> NSColor {
        NSColor(hex: icon.tintHex) ?? NSColor(hex: WrapIcon.defaultTintHex) ?? .systemBrown
    }
}

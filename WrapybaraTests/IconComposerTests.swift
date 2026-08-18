import AppKit
import XCTest
@testable import Wrapybara

/// Pixel-level checks for `IconComposer`.
///
/// The canvas geometry is deterministic, so these render the composed icon into a
/// bitmap and sample it: the failure mode being guarded against — artwork stretched
/// into a square — is invisible to a size-only assertion.
final class IconComposerTests: XCTestCase {

    // MARK: Aspect fitting

    func testAspectFitGeometry() {
        let wide = IconComposer.aspectFit(size: NSSize(width: 400, height: 100),
                                          in: NSRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(wide.width, 200, accuracy: 0.01)
        XCTAssertEqual(wide.height, 50, accuracy: 0.01)
        XCTAssertEqual(wide.midX, 100, accuracy: 0.01)
        XCTAssertEqual(wide.midY, 100, accuracy: 0.01)

        let tall = IconComposer.aspectFit(size: NSSize(width: 100, height: 400),
                                          in: NSRect(x: 0, y: 0, width: 200, height: 200))
        XCTAssertEqual(tall.width, 50, accuracy: 0.01)
        XCTAssertEqual(tall.height, 200, accuracy: 0.01)
        XCTAssertEqual(tall.midX, 100, accuracy: 0.01)
    }

    func testAspectFitLeavesSquareArtworkAlone() {
        let square = IconComposer.aspectFit(size: NSSize(width: 180, height: 180),
                                            in: NSRect(x: 10, y: 20, width: 300, height: 300))
        XCTAssertEqual(square, NSRect(x: 10, y: 20, width: 300, height: 300))
    }

    func testAspectFitFallsBackToBoundsForADegenerateSize() {
        let bounds = NSRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(IconComposer.aspectFit(size: .zero, in: bounds), bounds)
    }

    // MARK: Composition pixels

    /// Wide artwork on the plate keeps its proportions: the plate shows through
    /// above and below the fitted artwork rather than the artwork filling the box.
    func testWideArtworkIsFittedNotSquashedOnThePlate() throws {
        let artwork = solidImage(width: 400, height: 100, color: .red)
        let composed = IconComposer.compose(artwork: artwork, style: .plate,
                                            plate: IconPlate(colorHex: "#0000FF"))
        let rep = try bitmap(for: composed)
        // The sample coordinates below assume a 1024-pt canvas.
        XCTAssertEqual(composed.size, NSSize(width: 1024, height: 1024))

        let center = try XCTUnwrap(rep.colorAt(x: 512, y: 512))
        XCTAssertGreaterThan(center.redComponent, 0.8, "the fitted artwork should cover the centre")

        // y = 700 sits inside the square artwork box but outside a 4:1 image fitted
        // into it — whether the bitmap's y axis runs up or down (the box is
        // vertically centered, so both readings land on plate).
        let offArtwork = try XCTUnwrap(rep.colorAt(x: 512, y: 700))
        XCTAssertLessThan(offArtwork.redComponent, 0.5, "a squashed image would be red here")
        XCTAssertGreaterThan(offArtwork.blueComponent, 0.5, "the plate should show through here")
    }

    /// A pattern plate is flat two-tone, not a gradient: two paper bits sampled
    /// near the top and bottom of the plate are the same colour, and an ink bit
    /// reads against them.
    func testPatternPlateRendersFlatTwoToneTiles() throws {
        let artwork = solidImage(width: 400, height: 400, color: .red)
        let plate = IconPlate(colorHex: "#CC4400", pattern: .bricks)
        let composed = IconComposer.compose(artwork: artwork, style: .plate, plate: plate)
        let rep = try bitmap(for: composed)

        // Geometry: the plate spans 100…924, one pattern bit is 824/64 = 12.875 pt.
        // Both paper samples are in bit column 1 — x ≈ 119 — at bit rows 9 and 54,
        // where bricks have paper. They're equidistant from the vertical centre,
        // so if the bitmap's y axis reads the other way the two simply swap.
        let upperPaper = try XCTUnwrap(rep.colorAt(x: 119, y: 801))
        let lowerPaper = try XCTUnwrap(rep.colorAt(x: 119, y: 222))
        XCTAssertEqual(upperPaper.redComponent, lowerPaper.redComponent, accuracy: 0.03,
                       "a pattern plate is flat — a gradient would drift between these")

        // The ink sample sits on the plate's horizontal centreline, in the margin
        // left of the artwork box. Bricks have mortar at column 2 whether the
        // centreline reads as bit row 31 or 32, so the y-axis question is moot.
        let ink = try XCTUnwrap(rep.colorAt(x: 132, y: 500))
        XCTAssertGreaterThan(ink.redComponent, upperPaper.redComponent + 0.05,
                             "the ink tone should read against the paper tone")
    }

    /// The `.asIs` style letterboxes wide artwork instead of stretching it.
    func testAsIsStyleLetterboxesWideArtwork() throws {
        let artwork = solidImage(width: 400, height: 100, color: .red)
        let composed = IconComposer.compose(artwork: artwork, style: .asIs,
                                            plate: IconPlate(colorHex: "#0000FF"))
        let rep = try bitmap(for: composed)
        // The sample coordinates below assume a 1024-pt canvas.
        XCTAssertEqual(composed.size, NSSize(width: 1024, height: 1024))

        let center = try XCTUnwrap(rep.colorAt(x: 512, y: 512))
        XCTAssertGreaterThan(center.redComponent, 0.8)

        // 32 pt from an edge — inside the canvas, outside any 4:1 fit, from either
        // y-axis reading.
        let edge = try XCTUnwrap(rep.colorAt(x: 512, y: 32))
        XCTAssertLessThan(edge.alphaComponent, 0.1, "the letterbox band should be transparent")
    }

    // MARK: Helpers

    /// A solid-colour image of the given point size.
    private func solidImage(width: CGFloat, height: CGFloat, color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: width, height: height), flipped: false) { rect in
            color.setFill()
            rect.fill()
            return true
        }
    }

    /// Renders an image into a bitmap at its point size, for pixel sampling.
    private func bitmap(for image: NSImage) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(image.size.width), pixelsHigh: Int(image.size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        return rep
    }
}

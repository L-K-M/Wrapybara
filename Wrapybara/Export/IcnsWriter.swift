import AppKit

/// Writes an `.icns` file.
///
/// Written by hand rather than by shelling out to `iconutil`, so building a wrap
/// needs the Command Line Tools for exactly one thing (signing) instead of two —
/// and so the format is testable.
///
/// The container is simple: a `icns` magic, the total byte length, then a flat run
/// of `(type, length, data)` elements. Since OS X 10.7 every one of these element
/// types accepts PNG data directly, so each entry is just the artwork rendered at
/// that pixel size.
enum IcnsWriter {

    /// The element types written, paired with their pixel size.
    ///
    /// Two families, both required. `icp4`/`icp5` and `ic07`…`ic10` are the
    /// point-size slots; `ic11`…`ic14` are the `@2x` slots. Omitting the `@2x` set
    /// makes an app icon that looks soft in the Dock on a Retina display, which is
    /// exactly the "not a real Mac app" tell this whole project is trying to avoid.
    static let elements: [(type: String, pixels: Int)] = [
        ("icp4", 16),    // 16pt @1x
        ("icp5", 32),    // 32pt @1x
        ("ic11", 32),    // 16pt @2x
        ("ic12", 64),    // 32pt @2x
        ("ic07", 128),   // 128pt @1x
        ("ic13", 256),   // 128pt @2x
        ("ic08", 256),   // 256pt @1x
        ("ic14", 512),   // 256pt @2x
        ("ic09", 512),   // 512pt @1x
        ("ic10", 1024),  // 512pt @2x
    ]

    enum WriteError: LocalizedError {
        case renderFailed(Int)

        var errorDescription: String? {
            switch self {
            case .renderFailed(let size):
                return "Couldn't render the app icon at \(size)×\(size)."
            }
        }
    }

    /// The `.icns` bytes for `image`.
    static func data(for image: NSImage) throws -> Data {
        var body = Data()
        // Renders are cached by pixel size: several element types share a size
        // (ic13/ic08 are both 256), and rendering each twice would be wasteful.
        var rendered: [Int: Data] = [:]

        for element in elements {
            let png: Data
            if let cached = rendered[element.pixels] {
                png = cached
            } else {
                guard let fresh = pngData(from: image, pixels: element.pixels) else {
                    throw WriteError.renderFailed(element.pixels)
                }
                rendered[element.pixels] = fresh
                png = fresh
            }
            body.append(contentsOf: Array(element.type.utf8))
            body.append(bigEndian(UInt32(png.count + 8)))   // length includes this header
            body.append(png)
        }

        var file = Data()
        file.append(contentsOf: Array("icns".utf8))
        file.append(bigEndian(UInt32(body.count + 8)))
        file.append(body)
        return file
    }

    /// Writes the `.icns` for `image` to `url`.
    static func write(_ image: NSImage, to url: URL) throws {
        try data(for: image).write(to: url, options: [.atomic])
    }

    // MARK: Rendering

    /// `image` rasterised to a square `pixels`×`pixels` PNG.
    ///
    /// Draws into an explicitly sized `NSBitmapImageRep` rather than asking the
    /// `NSImage` for a representation, because a source with only one small
    /// representation (a 32×32 favicon, say) would otherwise hand back that
    /// representation's own size and produce a mismatched element.
    static func pngData(from image: NSImage, pixels: Int) -> Data? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                        pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4,
                                        hasAlpha: true, isPlanar: false,
                                        colorSpaceName: .deviceRGB,
                                        bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: pixels, height: pixels)

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
                   from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .png, properties: [:])
    }

    private static func bigEndian(_ value: UInt32) -> Data {
        Data([
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF),
        ])
    }
}

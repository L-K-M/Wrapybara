import AppKit
import SwiftUI

// MARK: - NSColor hex support

extension NSColor {
    /// Parses `#RRGGBB`, `#RRGGBBAA`, or the CSS shorthands `#RGB`/`#RGBA`
    /// (the leading `#` is optional).
    convenience init?(hex: String) {
        var string = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if string.hasPrefix("#") { string.removeFirst() }

        // `UInt64(_, radix:)` accepts a leading "+", so "+ABCDE" would otherwise
        // slip through as a 5-digit value and decode as the wrong color — require
        // pure hex digits before parsing (FAB-B15).
        guard !string.isEmpty, string.allSatisfy(\.isHexDigit) else { return nil }

        // Expand CSS shorthand by doubling each nibble: #abc → #aabbcc (L10).
        if string.count == 3 || string.count == 4 {
            string = string.map { "\($0)\($0)" }.joined()
        }

        guard let value = UInt64(string, radix: 16) else { return nil }

        let r, g, b, a: CGFloat
        switch string.count {
        case 6:
            r = CGFloat((value & 0xFF0000) >> 16) / 255
            g = CGFloat((value & 0x00FF00) >> 8) / 255
            b = CGFloat(value & 0x0000FF) / 255
            a = 1
        case 8:
            r = CGFloat((value & 0xFF00_0000) >> 24) / 255
            g = CGFloat((value & 0x00FF_0000) >> 16) / 255
            b = CGFloat((value & 0x0000_FF00) >> 8) / 255
            a = CGFloat(value & 0x0000_00FF) / 255
        default:
            return nil
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    /// `#RRGGBB` (fully opaque) or `#RRGGBBAA` (translucent) in the sRGB color
    /// space — emitting alpha only when present keeps existing opaque presets
    /// byte-identical while letting translucent colors round-trip (L9).
    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#000000" }
        // Clamp each channel to 0...1 first: extended-range / wide-gamut sources can
        // report components outside [0,1] even after `.sRGB`, which would otherwise
        // format to an out-of-range value that fails to round-trip through `init?(hex:)`
        // and silently becomes `.clear` (H19).
        func channel(_ v: CGFloat) -> Int { Int((Swift.min(Swift.max(v, 0), 1) * 255).rounded()) }
        let r = channel(c.redComponent)
        let g = channel(c.greenComponent)
        let b = channel(c.blueComponent)
        let a = channel(c.alphaComponent)
        return a < 255 ? String(format: "#%02X%02X%02X%02X", r, g, b, a)
                       : String(format: "#%02X%02X%02X", r, g, b)
    }
}

// MARK: - SwiftUI Color bridging

extension Color {
    /// Creates a `Color` from a `#RRGGBB[AA]` (or `#RGB[A]` shorthand) string,
    /// falling back to clear.
    init(hexString: String) {
        self = Color(nsColor: NSColor(hex: hexString) ?? .clear)
    }

    /// The hex string for this color (best-effort via `NSColor`).
    var hexString: String {
        NSColor(self).hexString
    }
}

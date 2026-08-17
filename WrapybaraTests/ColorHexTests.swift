import XCTest
import AppKit
import SwiftUI
@testable import Wrapybara

final class ColorHexTests: XCTestCase {

    func testParsesSixDigitHex() {
        let red = NSColor(hex: "#FF0000")
        XCTAssertNotNil(red)
        let srgb = red!.usingColorSpace(.sRGB)!
        XCTAssertEqual(srgb.redComponent, 1, accuracy: 0.01)
        XCTAssertEqual(srgb.greenComponent, 0, accuracy: 0.01)
        XCTAssertEqual(srgb.blueComponent, 0, accuracy: 0.01)
    }

    func testLeadingHashOptional() {
        XCTAssertNotNil(NSColor(hex: "00FF00"))
    }

    func testInvalidReturnsNil() {
        XCTAssertNil(NSColor(hex: "nothex"))
        XCTAssertNil(NSColor(hex: "#FFFFF"))  // 5 digits is not a valid form
        XCTAssertNil(NSColor(hex: ""))
        XCTAssertNil(NSColor(hex: "#"))
    }

    func testSignedHexRejected() {
        // `UInt64(_, radix: 16)` accepts a leading "+"; the parser must not (FAB-B15).
        XCTAssertNil(NSColor(hex: "+ABCDE"))
        XCTAssertNil(NSColor(hex: "+ABCDEF"))
        XCTAssertNil(NSColor(hex: "#+ABCDE"))
        XCTAssertNil(NSColor(hex: "-ABCDEF"))
    }

    func testShorthandRGBExpandsNibbles() {
        // #abc must decode exactly like #aabbcc (L10).
        XCTAssertEqual(NSColor(hex: "#abc")!.hexString, "#AABBCC")
        XCTAssertEqual(NSColor(hex: "#abc")!.hexString, NSColor(hex: "#aabbcc")!.hexString)
    }

    func testShorthandRGBAParsesWithAlpha() {
        let color = NSColor(hex: "#abcd")
        XCTAssertNotNil(color)
        let srgb = color!.usingColorSpace(.sRGB)!
        XCTAssertEqual(srgb.redComponent, CGFloat(0xAA) / 255, accuracy: 0.001)
        XCTAssertEqual(srgb.greenComponent, CGFloat(0xBB) / 255, accuracy: 0.001)
        XCTAssertEqual(srgb.blueComponent, CGFloat(0xCC) / 255, accuracy: 0.001)
        XCTAssertEqual(srgb.alphaComponent, CGFloat(0xDD) / 255, accuracy: 0.001)
    }

    func testHexStringRoundTrip() {
        XCTAssertEqual(NSColor(hex: "#3A7BD5")!.hexString, "#3A7BD5")
    }

    func testOpaqueColorEmitsSixDigits() {
        // Fully opaque stays #RRGGBB — even when parsed from an 8-digit string.
        XCTAssertEqual(NSColor(hex: "#3A7BD5FF")!.hexString, "#3A7BD5")
    }

    func testAlphaRoundTripsThroughHexString() {
        // Translucent colors emit #RRGGBBAA and survive a parse → format cycle (L9).
        XCTAssertEqual(NSColor(hex: "#3A7BD580")!.hexString, "#3A7BD580")
        XCTAssertEqual(NSColor(hex: "#3A7BD500")!.hexString, "#3A7BD500")
    }

    func testSwiftUIColorBridging() {
        XCTAssertEqual(Color(hexString: "#0A84FF").hexString, "#0A84FF")
    }
}

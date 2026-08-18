import AppKit
import XCTest
@testable import Wrapybara

/// `WindowGeometry` decides where a remembered window goes back — its frame, and
/// what to do when the screen it lived on is gone. Values in, values out: none of
/// this needs a real `NSScreen`, which is the point — the unplug-the-display cases
/// are exactly the ones a developer's own machine never shows.
final class WindowGeometryTests: XCTestCase {

    private func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
        NSRect(x: x, y: y, width: w, height: h)
    }

    /// A display-shaped screen: the menu bar owns the top 25pt, the Dock the
    /// bottom 45.
    private func screen(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat)
        -> WindowGeometry.Screen {
        WindowGeometry.Screen(frame: rect(x, y, w, h),
                              visibleFrame: rect(x, y + 45, w, h - 45 - 25))
    }

    // MARK: Codable

    func testRoundTripsThroughCodable() throws {
        let geometry = WindowGeometry(frame: rect(10, 20, 800, 600),
                                      screenFrame: rect(-1440, 0, 1440, 900),
                                      isFullScreen: true)
        let data = try JSONEncoder().encode(geometry)
        XCTAssertEqual(try JSONDecoder().decode(WindowGeometry.self, from: data), geometry)
    }

    func testDecodingFallsBackToDefaultsForMissingAndWrongKeys() throws {
        let empty = try JSONDecoder().decode(WindowGeometry.self,
                                             from: Data("{}".utf8))
        XCTAssertEqual(empty.frame, .zero)
        XCTAssertEqual(empty.screenFrame, .zero)
        XCTAssertFalse(empty.isFullScreen)
        XCTAssertFalse(empty.isUsable)

        // A wrong type degrades to the default for that key, not a failed load.
        let mistyped = try JSONDecoder().decode(WindowGeometry.self,
                                                from: Data(#"{"x": "left", "isFullScreen": 1}"#.utf8))
        XCTAssertEqual(mistyped.x, 0)
        XCTAssertFalse(mistyped.isFullScreen)
    }

    func testUsableGeometryIsRecognised() {
        let good = WindowGeometry(frame: rect(0, 0, 640, 480), screenFrame: .zero,
                                  isFullScreen: false)
        XCTAssertTrue(good.isUsable)
        XCTAssertFalse(WindowGeometry(frame: .zero, screenFrame: .zero,
                                      isFullScreen: false).isUsable)
    }

    // MARK: Restoring against the screens that exist now

    func testFrameIsUnchangedWhenTheSavedScreenStillMatches() {
        let geometry = WindowGeometry(frame: rect(100, 100, 800, 600),
                                      screenFrame: rect(0, 0, 1920, 1080),
                                      isFullScreen: false)
        let screens = [screen(0, 0, 1920, 1080), screen(1920, 0, 1920, 1080)]
        XCTAssertEqual(geometry.resolvedFrame(on: screens), rect(100, 100, 800, 600))
    }

    func testMissingScreenMovesTheWindowToTheScreenItOverlappedMost() {
        // Saved on a display that no longer exists, straddling (in dead-layout
        // coordinates) what are now two displays. It overlaps the right-hand one
        // more, and comes back fully inside that one's *visible* frame.
        let geometry = WindowGeometry(frame: rect(1200, 100, 600, 500),
                                      screenFrame: rect(0, 0, 1000, 1000),
                                      isFullScreen: false)
        let screens = [screen(0, 0, 1440, 900), screen(1440, 0, 1920, 1080)]
        XCTAssertEqual(geometry.resolvedFrame(on: screens), rect(1440, 100, 600, 500))
    }

    func testWindowLargerThanItsNewScreenIsCappedToTheVisibleFrame() {
        let geometry = WindowGeometry(frame: rect(100, 100, 2400, 1400),
                                      screenFrame: rect(0, 0, 3000, 2000),
                                      isFullScreen: false)
        let screens = [screen(0, 0, 1440, 900)]
        // 1440×830 is the visible frame (900 − 45 Dock − 25 menu bar); the origin
        // follows the size in, because a capped size can't keep a position that
        // was legal for the uncapped one.
        XCTAssertEqual(geometry.resolvedFrame(on: screens), rect(0, 45, 1440, 830))
    }

    func testFrameOverlappingNothingLandsOnTheFirstScreen() {
        let geometry = WindowGeometry(frame: rect(-1900, 100, 500, 400),
                                      screenFrame: rect(-2000, 0, 1000, 1000),
                                      isFullScreen: false)
        let screens = [screen(0, 0, 1440, 900), screen(1440, 0, 1920, 1080)]
        XCTAssertEqual(geometry.resolvedFrame(on: screens), rect(0, 100, 500, 400))
    }

    func testNoScreensLeavesTheSavedFrameAlone() {
        let geometry = WindowGeometry(frame: rect(10, 20, 800, 600),
                                      screenFrame: rect(0, 0, 1920, 1080),
                                      isFullScreen: false)
        XCTAssertEqual(geometry.resolvedFrame(on: []), rect(10, 20, 800, 600))
    }

    func testSavedFrameOffItsOwnSavedScreenIsStillConstrained() {
        // Corrupt or hand-edited data: the screen matches, but the frame isn't on
        // it. Trust no saved rectangle that can't be seen.
        let geometry = WindowGeometry(frame: rect(5000, 5000, 800, 600),
                                      screenFrame: rect(0, 0, 1920, 1080),
                                      isFullScreen: false)
        let screens = [screen(0, 0, 1920, 1080)]
        // Visible frame is (0, 45, 1920, 1010): 800×600 fits, so only the origin
        // clamps — to maxX−width = 1920−800 and maxY−height = 1055−600.
        XCTAssertEqual(geometry.resolvedFrame(on: screens), rect(1120, 455, 800, 600))
    }
}

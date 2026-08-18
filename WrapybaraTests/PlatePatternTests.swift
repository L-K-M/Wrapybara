import XCTest
@testable import Wrapybara

/// The classic plate tiles. The geometry is the contract: `IconComposer` draws
/// whatever `bit(column:row:)` says, so a malformed tile would ship as a visible
/// artefact on every icon — these pin the tiles down instead.
final class PlatePatternTests: XCTestCase {

    func testEveryPatternIsAFullTileWithInkAndPaper() {
        for pattern in PlatePattern.allCases {
            XCTAssertEqual(pattern.rows.count, PlatePattern.edge,
                           "\(pattern) must have exactly eight rows")
            let setBits = pattern.rows.reduce(0) { $0 + $1.nonzeroBitCount }
            XCTAssertGreaterThan(setBits, 0, "\(pattern) has no ink")
            XCTAssertLessThan(setBits, PlatePattern.edge * PlatePattern.edge,
                              "\(pattern) is solid ink — no pattern reads as one")
        }
    }

    func testBitReadsRowsTopToBottomColumnsLeftToRight() {
        // Bricks: the first row is a solid mortar line; the row below has mortar
        // only at columns 0 and 4.
        XCTAssertTrue(PlatePattern.bricks.bit(column: 3, row: 0))
        XCTAssertTrue(PlatePattern.bricks.bit(column: 0, row: 1))
        XCTAssertTrue(PlatePattern.bricks.bit(column: 4, row: 1))
        XCTAssertFalse(PlatePattern.bricks.bit(column: 1, row: 1))
    }

    func testBitCoordinatesWrapAroundTheTile() {
        for pattern in PlatePattern.allCases {
            for row in 0 ..< PlatePattern.edge {
                for column in 0 ..< PlatePattern.edge {
                    XCTAssertEqual(pattern.bit(column: column, row: row),
                                   pattern.bit(column: column + PlatePattern.edge,
                                               row: row + 2 * PlatePattern.edge),
                                   "\(pattern) should tile seamlessly at (\(column), \(row))")
                }
            }
        }
    }

    func testNegativeCoordinatesWrapToo() {
        XCTAssertEqual(PlatePattern.dither.bit(column: -1, row: 0),
                       PlatePattern.dither.bit(column: PlatePattern.edge - 1, row: 0))
        XCTAssertEqual(PlatePattern.dither.bit(column: 0, row: -1),
                       PlatePattern.dither.bit(column: 0, row: PlatePattern.edge - 1))
    }

    /// The diagonal stripe only works if the band leaving the right edge continues
    /// on the left one row down — that's what makes the tile seamless.
    func testStripesAreContinuousAcrossTheTileEdge() {
        for row in -16 ... 16 {
            XCTAssertEqual(PlatePattern.stripes.bit(column: PlatePattern.edge - 1, row: row),
                           PlatePattern.stripes.bit(column: 0, row: row + 1),
                           "the band should continue from the right edge to the left")
        }
    }

    func testMalformedArtLinesAreTruncatedOrPadded() {
        // The shipped constants are all well-formed (the geometry tests above);
        // this pins the parser's lenience so a future editing slip degrades to a
        // visible-but-valid tile rather than a crash.
        XCTAssertEqual(PlatePattern.byte(forLine: "########"), 0xFF)
        XCTAssertEqual(PlatePattern.byte(forLine: "#"), 0x80)
        XCTAssertEqual(PlatePattern.byte(forLine: "##########"), 0xFF)
        XCTAssertEqual(PlatePattern.byte(forLine: ""), 0x00)
    }

    func testRawValuesRoundTripThroughCodable() throws {
        for pattern in PlatePattern.allCases {
            let data = try JSONEncoder().encode(pattern)
            XCTAssertEqual(try JSONDecoder().decode(PlatePattern.self, from: data), pattern)
        }
    }
}

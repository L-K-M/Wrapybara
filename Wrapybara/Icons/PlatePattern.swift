import Foundation

/// One of the classic Mac desktop tiles, offered as an icon-plate background.
///
/// The System 7–9 "Desktop Patterns" control panel tiled the desktop with 8×8,
/// one-bit patterns; drawn in two tones of the plate colour, they read instantly
/// as *that* era of Mac. Each pattern is stored as eight lines of ASCII art —
/// `#` is ink, anything else is paper — which keeps the tile reviewable at a
/// glance in a way eight hex bytes never are.
///
/// Pure value in, value out: the geometry is unit-tested, and `IconComposer`
/// does the AppKit drawing.
enum PlatePattern: String, Codable, CaseIterable, Identifiable {

    /// The System 7 default desktop: a 50% checkerboard dither.
    case dither
    /// Basket weave, two-by-two blocks alternating direction.
    case weave
    /// Running-bond brickwork.
    case bricks
    /// Offset polka dots.
    case dots
    /// Touching diamonds — the argyle tile.
    case diamonds
    /// A seamless 45° diagonal stripe.
    case stripes
    /// A plain lattice grid.
    case lattice

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .dither: return "Dither"
        case .weave: return "Basket Weave"
        case .bricks: return "Bricks"
        case .dots: return "Polka Dots"
        case .diamonds: return "Diamonds"
        case .stripes: return "Diagonal Stripes"
        case .lattice: return "Lattice"
        }
    }

    /// The tile edge in bits. Classic tiles are 8×8; nothing here bends that.
    static let edge = 8

    /// The tile as eight bytes, row 0 at the top, column 0 the most significant
    /// bit. Parsed from `art` on every call — an icon render asks for a few
    /// thousand bits, and clarity beats caching here.
    var rows: [UInt8] {
        var bytes = art.map(Self.byte(forLine:))
        // The constants below are all well-formed; the padding only keeps a
        // future edit that drops a line from crashing bit lookups instead of
        // failing the geometry tests.
        while bytes.count < Self.edge { bytes.append(0) }
        return Array(bytes.prefix(Self.edge))
    }

    /// The bit at `column`/`row`, wrapping at the tile edge (negative coordinates
    /// included), so tiling code can ask for any point without bounds juggling.
    func bit(column: Int, row: Int) -> Bool {
        let wrappedColumn = ((column % Self.edge) + Self.edge) % Self.edge
        let wrappedRow = ((row % Self.edge) + Self.edge) % Self.edge
        return (rows[wrappedRow] & (0x80 >> wrappedColumn)) != 0
    }

    /// One line of art to a byte: `#` sets the bit, everything else is paper.
    /// Over-long lines are truncated, short ones zero-padded — the geometry tests
    /// pin the real constants to full rows.
    static func byte(forLine line: String) -> UInt8 {
        var byte: UInt8 = 0
        for (index, character) in line.prefix(Self.edge).enumerated() where character == "#" {
            byte |= 0x80 >> index
        }
        return byte
    }

    /// The tiles, top row first. `#` is ink, `.` is paper.
    private var art: [String] {
        switch self {
        case .dither:
            return [
                "#.#.#.#.",
                ".#.#.#.#",
                "#.#.#.#.",
                ".#.#.#.#",
                "#.#.#.#.",
                ".#.#.#.#",
                "#.#.#.#.",
                ".#.#.#.#",
            ]
        case .weave:
            return [
                "##..##..",
                "##..##..",
                "..##..##",
                "..##..##",
                "##..##..",
                "##..##..",
                "..##..##",
                "..##..##",
            ]
        case .bricks:
            return [
                "########",
                "#...#...",
                "#...#...",
                "#...#...",
                "########",
                "..#...#.",
                "..#...#.",
                "..#...#.",
            ]
        case .dots:
            return [
                "........",
                ".##.....",
                ".##.....",
                "........",
                "........",
                ".....##.",
                ".....##.",
                "........",
            ]
        case .diamonds:
            return [
                "...##...",
                "..####..",
                ".######.",
                "########",
                "########",
                ".######.",
                "..####..",
                "...##...",
            ]
        case .stripes:
            // The band moves one column right per row and re-enters on the left
            // exactly where it exited on the right — the seamlessness test pins
            // that property.
            return [
                "##......",
                ".##.....",
                "..##....",
                "...##...",
                "....##..",
                ".....##.",
                "......##",
                "#.....##",
            ]
        case .lattice:
            return [
                "..#...#.",
                "..#...#.",
                "..#...#.",
                "########",
                "..#...#.",
                "..#...#.",
                "..#...#.",
                "########",
            ]
        }
    }
}

import XCTest
@testable import Wrapybara

final class SemanticVersionTests: XCTestCase {

    func testParsesAndCompares() {
        XCTAssertTrue(SemanticVersion("1.2.3")! > SemanticVersion("1.2.0")!)
        XCTAssertTrue(SemanticVersion("2.0.0")! > SemanticVersion("1.9.9")!)
    }

    func testLeadingVAndPadding() {
        XCTAssertEqual(SemanticVersion("v1.2")!, SemanticVersion("1.2.0")!)
    }

    func testPrereleaseSortsBelowRelease() {
        XCTAssertTrue(SemanticVersion("1.2.0-beta")! < SemanticVersion("1.2.0")!)
    }

    func testPrereleaseUsesSemVerIdentifierOrdering() {
        XCTAssertTrue(SemanticVersion("1.2.0-beta.2")! < SemanticVersion("1.2.0-beta.10")!)
        XCTAssertTrue(SemanticVersion("1.2.0-1")! < SemanticVersion("1.2.0-alpha")!)
        XCTAssertTrue(SemanticVersion("1.2.0-alpha")! < SemanticVersion("1.2.0-alpha.1")!)
        XCTAssertTrue(SemanticVersion("1.2.0-alpha.1")! < SemanticVersion("1.2.0-alpha.beta")!)
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(SemanticVersion("latest"))
        XCTAssertNil(SemanticVersion(""))
    }

    func testRejectsLeadingZerosInReleaseComponents() {
        XCTAssertNil(SemanticVersion("01.2.3"))
        XCTAssertNil(SemanticVersion("1.02.3"))
        XCTAssertNil(SemanticVersion("1.2.03"))
    }

    func testRejectsLeadingZerosInNumericPrereleaseIdentifiers() {
        XCTAssertNil(SemanticVersion("1.0.0-01"))
        XCTAssertNil(SemanticVersion("1.0.0-alpha.01"))
    }

    func testAcceptsSingleZeroAndAlphanumericPrereleaseIdentifiers() {
        XCTAssertNotNil(SemanticVersion("0.1.0"))
        XCTAssertNotNil(SemanticVersion("1.0.0-0"))
        XCTAssertNotNil(SemanticVersion("1.0.0-alpha01"))
    }

    func testRejectsEmptyPrereleaseIdentifiers() {
        XCTAssertNil(SemanticVersion("1.0.0-"))
        XCTAssertNil(SemanticVersion("1.0.0-alpha..1"))
    }

    func testRejectsInvalidPrereleaseCharacters() {
        XCTAssertNil(SemanticVersion("1.0.0-alpha_1"))
        XCTAssertNil(SemanticVersion("1.0.0-alpha beta"))
        XCTAssertNil(SemanticVersion("1.0.0-١"))
    }

    func testLargeNumericPrereleaseIdentifiersDoNotOverflow() {
        let smaller = SemanticVersion("1.0.0-9223372036854775808")!
        let larger = SemanticVersion("1.0.0-10000000000000000000")!
        XCTAssertLessThan(smaller, larger)
    }
}

import XCTest
@testable import Wrapybara

final class BadgeFromTitleTests: XCTestCase {

    // MARK: The common shapes

    func testLeadingParenthesisedCount() {
        XCTAssertEqual(BadgeFromTitle.badge(for: "(3) Inbox"), "3")
        XCTAssertEqual(BadgeFromTitle.badge(for: "[12] Slack"), "12")
        XCTAssertEqual(BadgeFromTitle.badge(for: "{7} Notifications"), "7")
    }

    func testTrailingParenthesisedCount() {
        XCTAssertEqual(BadgeFromTitle.badge(for: "Inbox (5)"), "5")
    }

    func testGroupingSeparators() {
        XCTAssertEqual(BadgeFromTitle.badge(for: "(1,234) Inbox"), "1234")
        XCTAssertEqual(BadgeFromTitle.badge(for: "(1.234) Inbox"), "1234")
        XCTAssertEqual(BadgeFromTitle.badge(for: "(12 345) Inbox"), "12345")
    }

    func testCappedForm() {
        XCTAssertEqual(BadgeFromTitle.badge(for: "(99+) Inbox"), "99+")
        XCTAssertEqual(BadgeFromTitle.badge(for: "Inbox (99+)"), "99+")
    }

    func testUnreadMarkerWithoutACount() {
        XCTAssertEqual(BadgeFromTitle.badge(for: "• Notion — Roadmap"), "•")
        XCTAssertEqual(BadgeFromTitle.badge(for: "* Figma"), "•")
    }

    // MARK: No badge

    func testPlainTitleHasNoBadge() {
        XCTAssertNil(BadgeFromTitle.badge(for: "Inbox"))
        XCTAssertNil(BadgeFromTitle.badge(for: nil))
        XCTAssertNil(BadgeFromTitle.badge(for: ""))
        XCTAssertNil(BadgeFromTitle.badge(for: "   "))
    }

    func testZeroClearsTheBadgeRatherThanShowingZero() {
        XCTAssertNil(BadgeFromTitle.badge(for: "(0) Inbox"))
    }

    func testNonNumericBracketsAreIgnored() {
        XCTAssertNil(BadgeFromTitle.badge(for: "(beta) Dashboard"))
        XCTAssertNil(BadgeFromTitle.badge(for: "Report (2024–2025)"))
        XCTAssertNil(BadgeFromTitle.badge(for: "(draft) Notes"))
    }

    func testBareNumbersAreIgnored() {
        // Page titles are full of years, versions and prices.
        XCTAssertNil(BadgeFromTitle.badge(for: "Q3 2024 results"))
        XCTAssertNil(BadgeFromTitle.badge(for: "Swift 6 release notes"))
    }

    func testLeadingZeroIsNotACount() {
        XCTAssertNil(BadgeFromTitle.badge(for: "(007) Bond"))
    }

    func testMarkerAloneIsNotABadge() {
        XCTAssertNil(BadgeFromTitle.badge(for: "•"))
        XCTAssertNil(BadgeFromTitle.badge(for: "•   "))
    }

    // MARK: The asymmetry between the two positions

    func testTrailingFourDigitNumbersAreRejected() {
        // The whole point of the position asymmetry: `Annual Report (2024)` is a year, not
        // 2,024 unread items.
        XCTAssertNil(BadgeFromTitle.badge(for: "Annual Report (2024)"))
        XCTAssertNil(BadgeFromTitle.badge(for: "Budget (1999)"))
    }

    func testLeadingFourDigitNumbersAreAccepted() {
        // A leading `(n)` is the unread-count convention and essentially never anything
        // else, so it takes larger counts.
        XCTAssertEqual(BadgeFromTitle.badge(for: "(2024) Inbox"), "2024")
    }

    func testTrailingThreeDigitCountsStillWork() {
        XCTAssertEqual(BadgeFromTitle.badge(for: "Inbox (999)"), "999")
    }

    // MARK: Grouping validation

    func testVersionsAndPricesAreNotGroupedNumbers() {
        XCTAssertNil(BadgeFromTitle.normalizedCount("1.2.3"))
        XCTAssertNil(BadgeFromTitle.normalizedCount("12,5"))
        XCTAssertNil(BadgeFromTitle.normalizedCount("1,23"))
    }

    func testGroupingShapes() {
        XCTAssertTrue(BadgeFromTitle.isPlausibleGrouping("1,234", separatorCount: 1))
        XCTAssertTrue(BadgeFromTitle.isPlausibleGrouping("12,345,678", separatorCount: 2))
        XCTAssertFalse(BadgeFromTitle.isPlausibleGrouping("1,23", separatorCount: 1))
        XCTAssertFalse(BadgeFromTitle.isPlausibleGrouping("1234,5", separatorCount: 1))
    }

    // MARK: Numeric accessor

    func testCountAccessor() {
        XCTAssertEqual(BadgeFromTitle.count(for: "(42) Inbox"), 42)
        // A capped or bullet badge has no integer to report.
        XCTAssertNil(BadgeFromTitle.count(for: "(99+) Inbox"))
        XCTAssertNil(BadgeFromTitle.count(for: "• Inbox"))
        XCTAssertNil(BadgeFromTitle.count(for: "Inbox"))
    }
}

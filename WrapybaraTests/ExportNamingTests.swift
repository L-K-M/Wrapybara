import XCTest
@testable import Wrapybara

/// `AppNameSanitizer` and `BundleIdentifierGenerator`: what a typed name becomes on
/// disk, and the identifier that keys the generated app's session forever.
final class ExportNamingTests: XCTestCase {

    // MARK: File names

    func testOrdinaryNamePassesThrough() {
        XCTAssertEqual(AppNameSanitizer.fileName(for: "Proton Mail"), "Proton Mail")
    }

    func testPathSeparatorsBecomeSpaces() {
        // Deleting them would run two words together; Finder shows ":" as "/" too.
        XCTAssertEqual(AppNameSanitizer.fileName(for: "Mail/Calendar"), "Mail Calendar")
        XCTAssertEqual(AppNameSanitizer.fileName(for: "A:B"), "A B")
        XCTAssertEqual(AppNameSanitizer.fileName(for: "a/b/c"), "a b c")
    }

    func testLeadingDotIsStripped() {
        // A leading dot would make the app invisible in Finder.
        XCTAssertEqual(AppNameSanitizer.fileName(for: ".hidden"), "hidden")
        XCTAssertEqual(AppNameSanitizer.fileName(for: "...x"), "x")
    }

    func testTrailingDotsAndSpacesAreStripped() {
        XCTAssertEqual(AppNameSanitizer.fileName(for: "App."), "App")
        XCTAssertEqual(AppNameSanitizer.fileName(for: "App   "), "App")
    }

    func testControlCharactersAreRemoved() {
        XCTAssertEqual(AppNameSanitizer.fileName(for: "A\u{0000}B\nC"), "ABC")
    }

    func testEmptyNameFallsBack() {
        XCTAssertEqual(AppNameSanitizer.fileName(for: ""), AppNameSanitizer.fallback)
        XCTAssertEqual(AppNameSanitizer.fileName(for: "///"), AppNameSanitizer.fallback)
        XCTAssertEqual(AppNameSanitizer.fileName(for: "..."), AppNameSanitizer.fallback)
    }

    func testWindowsReservedNamesAreAvoided() {
        // These are device files on Windows and break SMB/exFAT volumes.
        XCTAssertEqual(AppNameSanitizer.fileName(for: "NUL"), "NUL App")
        XCTAssertEqual(AppNameSanitizer.fileName(for: "com1"), "com1 App")
        XCTAssertEqual(AppNameSanitizer.fileName(for: "Console"), "Console")
    }

    func testLongNamesAreCapped() {
        let name = String(repeating: "x", count: 400)
        XCTAssertEqual(AppNameSanitizer.fileName(for: name).count, AppNameSanitizer.maxLength)
    }

    func testUnicodeIsPreserved() {
        // A file name is not a bundle identifier; there's no reason to flatten it.
        XCTAssertEqual(AppNameSanitizer.fileName(for: "Café Notes"), "Café Notes")
        XCTAssertEqual(AppNameSanitizer.fileName(for: "日本語"), "日本語")
    }

    func testUniqueFileName() {
        XCTAssertEqual(AppNameSanitizer.uniqueFileName(for: "Mail", avoiding: []), "Mail")
        XCTAssertEqual(AppNameSanitizer.uniqueFileName(for: "Mail", avoiding: ["Mail"]), "Mail 2")
        XCTAssertEqual(AppNameSanitizer.uniqueFileName(for: "Mail", avoiding: ["Mail", "Mail 2"]),
                       "Mail 3")
    }

    // MARK: Bundle identifiers

    func testIdentifierReversesHostLabels() {
        XCTAssertEqual(BundleIdentifierGenerator.identifier(forHost: "claude.ai", name: "Claude"),
                       "com.wrapybara.site.ai.claude")
    }

    func testIdentifierAppendsADistinctName() {
        // Two wraps of one site (work and personal) must not collide, or they'd share a
        // cookie store and one login.
        XCTAssertEqual(
            BundleIdentifierGenerator.identifier(forHost: "mail.google.com", name: "Gmail Work"),
            "com.wrapybara.site.com.google.mail.gmail-work")
    }

    func testIdentifierDropsANameThatRepeatsTheSiteLabel() {
        XCTAssertEqual(BundleIdentifierGenerator.identifier(forHost: "claude.ai", name: "claude"),
                       "com.wrapybara.site.ai.claude")
    }

    func testIdentifierFoldsDiacriticsRatherThanDroppingThem() {
        XCTAssertEqual(BundleIdentifierGenerator.component("Café"), "cafe")
        XCTAssertEqual(BundleIdentifierGenerator.component("Über Notes"), "uber-notes")
    }

    func testComponentAllowsOnlyIdentifierCharacters() {
        XCTAssertEqual(BundleIdentifierGenerator.component("A B_C!D"), "a-b-c-d")
        XCTAssertEqual(BundleIdentifierGenerator.component("-beta-"), "beta")
        XCTAssertEqual(BundleIdentifierGenerator.component("日本語"), "")
        XCTAssertEqual(BundleIdentifierGenerator.component("1password"), "1password")
    }

    func testIdentifierNeverCollapsesToTheBarePrefix() {
        let identifier = BundleIdentifierGenerator.identifier(forHost: "", name: "")
        XCTAssertEqual(identifier, "\(BundleIdentifierGenerator.prefix).app")
    }

    func testIdentifierIsNeverTheBuilderIdentifier() {
        // Colliding with Wrapybara itself would make Launch Services open the wrong app.
        let identifier = BundleIdentifierGenerator.identifier(forHost: "wrapybara.com",
                                                             name: "Wrapybara")
        XCTAssertNotEqual(identifier, "com.wrapybara.Wrapybara")
        XCTAssertTrue(identifier.hasPrefix(BundleIdentifierGenerator.prefix))
    }

    func testUniqueIdentifierSuffixes() {
        guard let url = URL(string: "https://claude.ai") else { return XCTFail("bad URL") }
        let base = BundleIdentifierGenerator.identifier(for: url, name: "Claude")
        XCTAssertEqual(BundleIdentifierGenerator.uniqueIdentifier(for: url, name: "Claude",
                                                                 avoiding: [base]),
                       base + "-2")
    }

    func testIdentifierIsDeterministic() {
        guard let url = URL(string: "https://app.example.com/x") else { return XCTFail("bad URL") }
        XCTAssertEqual(BundleIdentifierGenerator.identifier(for: url, name: "Thing"),
                       BundleIdentifierGenerator.identifier(for: url, name: "Thing"))
    }
}

import XCTest
@testable import Wrapybara

final class URLNormalizerTests: XCTestCase {

    // MARK: Promotion

    func testBareHostBecomesHTTPS() {
        XCTAssertEqual(URLNormalizer.url(from: "claude.ai")?.absoluteString, "https://claude.ai")
    }

    func testBareHostWithPathBecomesHTTPS() {
        XCTAssertEqual(URLNormalizer.url(from: "claude.ai/new")?.absoluteString,
                       "https://claude.ai/new")
    }

    func testNeverPromotesToPlainHTTP() {
        // A wrap is long-lived; it shouldn't start life on a downgradeable scheme.
        XCTAssertEqual(URLNormalizer.url(from: "example.com")?.scheme, "https")
    }

    func testExplicitHTTPIsRespected() {
        XCTAssertEqual(URLNormalizer.url(from: "http://intranet.local/app")?.scheme, "http")
    }

    func testLocalhostIsAccepted() {
        XCTAssertEqual(URLNormalizer.url(from: "localhost:3000")?.absoluteString,
                       "https://localhost:3000")
    }

    func testWhitespaceIsTrimmed() {
        XCTAssertEqual(URLNormalizer.url(from: "  claude.ai  ")?.absoluteString,
                       "https://claude.ai")
    }

    // MARK: Rejection

    func testSearchPhrasesAreRejected() {
        // Somebody typing a question into the address field should get an error, not a
        // navigation to a hostname that can't exist.
        XCTAssertNil(URLNormalizer.url(from: "how do I wrap a site"))
        XCTAssertNil(URLNormalizer.url(from: "hello"))
        XCTAssertNil(URLNormalizer.url(from: ""))
        XCTAssertNil(URLNormalizer.url(from: "   "))
    }

    func testNonWebSchemesAreRejected() {
        XCTAssertNil(URLNormalizer.url(from: "javascript://alert(1)"))
        XCTAssertNil(URLNormalizer.url(from: "file:///etc/passwd"))
        XCTAssertNil(URLNormalizer.url(from: "ftp://example.com"))
    }

    func testMalformedHostsAreRejected() {
        XCTAssertNil(URLNormalizer.url(from: ".example.com"))
        XCTAssertNil(URLNormalizer.url(from: "example.com."))
    }

    // MARK: Scheme detection

    func testSchemeDetectionIgnoresHostColons() {
        // `URL(string:)` reports a scheme for `mail.google.com:443/x`, which would make the
        // promotion logic skip a host that needs it.
        XCTAssertNil(URLNormalizer.scheme(of: "mail.google.com:443/x"))
        XCTAssertEqual(URLNormalizer.scheme(of: "HTTPS://example.com"), "https")
        XCTAssertEqual(URLNormalizer.scheme(of: "custom-scheme+x://a"), "custom-scheme+x")
        XCTAssertNil(URLNormalizer.scheme(of: "1http://example.com"))
    }

    // MARK: Display

    func testDisplayStringDropsWWWAndTrailingSlash() {
        XCTAssertEqual(displayString("https://www.example.com/"), "example.com")
        XCTAssertEqual(displayString("https://example.com/docs/intro"), "example.com/docs/intro")
    }

    func testDisplayStringMarksAQuery() {
        XCTAssertEqual(displayString("https://example.com/s?q=x"), "example.com/s?…")
    }

    func testDisplayStringTruncates() {
        let long = "https://example.com/" + String(repeating: "a", count: 200)
        let display = URLNormalizer.displayString(for: URL(string: long)!, maxLength: 30)
        XCTAssertEqual(display.count, 30)
        XCTAssertTrue(display.hasSuffix("…"))
    }

    private func displayString(_ string: String) -> String {
        URLNormalizer.displayString(for: URL(string: string)!)
    }

    // MARK: Name suggestion

    func testSuggestedName() {
        XCTAssertEqual(suggested("https://claude.ai"), "Claude")
        XCTAssertEqual(suggested("https://www.notion.so/x"), "Notion")
        XCTAssertEqual(suggested("https://mail.proton.me"), "Proton")
        XCTAssertEqual(suggested("https://app.example.co.uk"), "Example")
        XCTAssertEqual(suggested("https://localhost:3000"), "Localhost")
    }

    private func suggested(_ string: String) -> String {
        URLNormalizer.suggestedName(for: URL(string: string)!)
    }
}

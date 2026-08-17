import XCTest
@testable import Wrapybara

/// The error page's pure surface: when it shows, what it contains, and that the
/// strings it interpolates can't break out of the markup.
final class SiteErrorPageTests: XCTestCase {

    // MARK: When to show

    func testOfflineErrorsShowThePage() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let noHost = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost)
        let timeout = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        XCTAssertTrue(SiteErrorPage.shouldShow(for: offline))
        XCTAssertTrue(SiteErrorPage.shouldShow(for: noHost))
        XCTAssertTrue(SiteErrorPage.shouldShow(for: timeout))
    }

    func testCancellationsNeverShowThePage() {
        let cancelled = NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
        XCTAssertFalse(SiteErrorPage.shouldShow(for: cancelled))
    }

    func testWebKitDomainErrorsDontClobberThePage() {
        // "Frame load interrupted" is what a navigation that became a *download*
        // looks like — the page must stay.
        let interrupted = NSError(domain: "WebKitErrorDomain", code: 102)
        XCTAssertFalse(SiteErrorPage.shouldShow(for: interrupted))
    }

    // MARK: Content

    private func page(name: String = "Example",
                      url: String = "https://example.com/inbox?a=1&b=2",
                      tint: String = "#FF0000") -> String {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        return SiteErrorPage.html(wrapName: name,
                                  failedURL: URL(string: url)!,
                                  error: error,
                                  tintHex: tint)
    }

    func testPageNamesTheWrapAndTheAddressAndOffersRetry() {
        let html = page()
        XCTAssertTrue(html.contains("<h1>Example couldn"))
        XCTAssertTrue(html.contains("couldn't open the page</h1>"))
        XCTAssertTrue(html.contains("Try Again"))
        // The retry target is the failed URL, as a real link, so a click is an
        // ordinary in-app navigation through NavigationPolicy.
        XCTAssertTrue(html.contains("href=\"https://example.com/inbox?a=1&amp;b=2\""))
    }

    func testPageUsesTheWrapTintForTheButton() {
        XCTAssertTrue(page(tint: "#FF0000").contains("background: #ff0000"))
    }

    func testAnUnreadableTintFallsBackToTheBrandBrown() {
        XCTAssertTrue(page(tint: "not a colour").contains("background: #8b5a2b"))
    }

    func testDarkModeIsSupported() {
        XCTAssertTrue(page().contains("prefers-color-scheme: dark"))
    }

    // MARK: Escaping

    func testAHostileWrapNameCannotBreakOutOfTheMarkup() {
        let html = page(name: "<script>alert(1)</script>")
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
    }

    func testEscapingCoversAllFiveCharacters() {
        XCTAssertEqual(SiteErrorPage.htmlEscaped(#"&<>"'"#), "&amp;&lt;&gt;&quot;&#39;")
    }
}

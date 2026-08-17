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

    // MARK: Failing URL

    func testFailingURLPrefersTheErrorsOwnURL() {
        // A → 301 → B failing at B must name (and retry) B, not A.
        let finalURL = URL(string: "https://example.com/after-redirect")!
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                            userInfo: [NSURLErrorFailingURLErrorKey: finalURL])
        let tracked = URL(string: "https://example.com/before-redirect")!
        XCTAssertEqual(SiteErrorPage.failingURL(for: error, fallbacks: [tracked]), finalURL)
    }

    func testFailingURLReadsTheStringForm() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorCannotFindHost,
                            userInfo: [NSURLErrorFailingURLStringErrorKey: "https://example.com/final"])
        XCTAssertEqual(SiteErrorPage.failingURL(for: error, fallbacks: [nil]),
                       URL(string: "https://example.com/final"))
    }

    func testFailingURLRejectsNonWebSchemesFromTheError() {
        // The error's own values are typo- and attacker-shaped; only http(s) is
        // taken from them, everything else falls through to the app's URLs.
        let malicious = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL,
                                userInfo: [NSURLErrorFailingURLStringErrorKey: "javascript:alert(1)"])
        let safe = URL(string: "https://fallback.example.com")!
        XCTAssertEqual(SiteErrorPage.failingURL(for: malicious, fallbacks: [safe]), safe)

        let dataURL = NSError(domain: NSURLErrorDomain, code: NSURLErrorBadURL,
                              userInfo: [NSURLErrorFailingURLStringErrorKey: "data:text/html,hi"])
        XCTAssertEqual(SiteErrorPage.failingURL(for: dataURL, fallbacks: [safe]), safe)
    }

    func testFallingBackInOrder() {
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let first = URL(string: "https://a.example.com")!
        let second = URL(string: "https://b.example.com")!
        XCTAssertEqual(SiteErrorPage.failingURL(for: error, fallbacks: [nil, first, second]), first)
    }

    func testNonWebFallbacksAreSkipped() {
        // Try Again has to be a page load; an about:blank or file: fallback is
        // skipped in favour of the next web URL in the chain.
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorTimedOut)
        let blank = URL(string: "about:blank")!
        let real = URL(string: "https://real.example.com")!
        XCTAssertEqual(SiteErrorPage.failingURL(for: error, fallbacks: [blank, real]), real)
    }

    // MARK: Button contrast

    func testLightTintsGetDarkButtonText() {
        XCTAssertEqual(SiteErrorPage.readableTextColor(onHex: "#F5F5F0"), "#1d1d1f")
        XCTAssertTrue(page(tint: "#F5F5F0").contains("color: #1d1d1f"))
    }

    func testDarkTintsGetWhiteButtonText() {
        XCTAssertEqual(SiteErrorPage.readableTextColor(onHex: "#8B5A2B"), "#ffffff")
        XCTAssertTrue(page(tint: "#8B5A2B").contains("color: #ffffff"))
    }

    func testAnUnreadableTintFallsBackToWhiteText() {
        XCTAssertEqual(SiteErrorPage.readableTextColor(onHex: "bogus"), "#ffffff")
    }
}

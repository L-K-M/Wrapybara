import XCTest
@testable import Wrapybara

final class BoostMatcherTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // The matcher caches compiled expressions across calls; start each test clean so
        // one test's pattern can't satisfy another's assertion.
        BoostMatcher.clearCache()
    }

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else {
            XCTFail("bad test URL \(string)")
            return URL(fileURLWithPath: "/")
        }
        return url
    }

    // MARK: Everywhere

    func testEverywhereMatchesAnything() {
        XCTAssertTrue(BoostMatcher.matches(.everywhere, url: url("https://example.com/a/b?c=d")))
        XCTAssertTrue(BoostMatcher.matches(.everywhere, url: url("about:blank")))
    }

    // MARK: Domain

    func testDomainMatchesExactHost() {
        let match = BoostMatch.domain("example.com")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/")))
    }

    func testDomainIncludesSubdomainsByDefault() {
        let match = BoostMatch.domain("example.com")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://mail.example.com/inbox")))
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://a.b.example.com/")))
    }

    func testDomainCanExcludeSubdomains() {
        let match = BoostMatch(kind: .domain, pattern: "example.com", includesSubdomains: false)
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/")))
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://mail.example.com/")))
    }

    func testDomainDoesNotMatchSuffixWithoutDotBoundary() {
        // "notexample.com" ends with "example.com" as a *string*, but is a different site.
        let match = BoostMatch.domain("example.com")
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://notexample.com/")))
    }

    func testDomainIsCaseInsensitive() {
        let match = BoostMatch.domain("Example.COM")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://EXAMPLE.com/")))
    }

    func testDomainToleratesAPastedURL() {
        // People paste URLs into fields labelled "domain".
        for pattern in ["https://example.com/", "example.com:8443", "https://user@example.com/x",
                        ".example.com.", "//example.com"] {
            let match = BoostMatch(kind: .domain, pattern: pattern)
            XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/")),
                          "pattern \(pattern) should normalise to example.com")
        }
    }

    func testEmptyDomainMatchesNothing() {
        XCTAssertFalse(BoostMatcher.matches(BoostMatch(kind: .domain, pattern: "  "),
                                           url: url("https://example.com/")))
    }

    func testDomainDoesNotMatchHostlessURL() {
        XCTAssertFalse(BoostMatcher.matches(BoostMatch.domain("example.com"), url: url("about:blank")))
    }

    // MARK: URL prefix

    func testURLPrefix() {
        let match = BoostMatch(kind: .urlPrefix, pattern: "https://example.com/docs")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/docs/intro")))
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://example.com/blog")))
    }

    func testEmptyURLPrefixMatchesNothing() {
        XCTAssertFalse(BoostMatcher.matches(BoostMatch(kind: .urlPrefix, pattern: ""),
                                            url: url("https://example.com/")))
    }

    // MARK: Glob

    func testGlobStarSpansPathSegments() {
        let match = BoostMatch(kind: .glob, pattern: "https://example.com/*/settings")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/team/settings")))
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/a/b/settings")))
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://example.com/settings/extra")))
    }

    func testGlobIsAnchoredAtBothEnds() {
        let match = BoostMatch(kind: .glob, pattern: "https://example.com/x")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/x")))
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://example.com/x/y")))
    }

    func testGlobQuestionMarkMatchesOneCharacter() {
        let match = BoostMatch(kind: .glob, pattern: "https://example.com/?")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/a")))
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://example.com/ab")))
    }

    func testGlobTreatsRegexMetacharactersAsLiterals() {
        // A real URL is full of `.` and `?`; neither may act as a regex metacharacter.
        let match = BoostMatch(kind: .glob, pattern: "https://example.com/a.b")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/a.b")))
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://example.com/axb")))
    }

    func testGlobIsCaseInsensitiveByDefault() {
        let match = BoostMatch(kind: .glob, pattern: "https://example.com/DOCS*")
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/docs/x")))
    }

    func testGlobCaseSensitivity() {
        let match = BoostMatch(kind: .glob, pattern: "https://example.com/DOCS*",
                               isCaseSensitive: true)
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://example.com/docs/x")))
    }

    func testGlobPatternTranslation() {
        XCTAssertEqual(BoostMatcher.regexPattern(forGlob: "a*b?c"), "^a.*b.c$")
        XCTAssertEqual(BoostMatcher.regexPattern(forGlob: "a.b"), "^a\\.b$")
    }

    // MARK: Regex

    func testRegexIsUnanchored() {
        let match = BoostMatch(kind: .regex, pattern: #"/inbox/\d+"#)
        XCTAssertTrue(BoostMatcher.matches(match, url: url("https://example.com/inbox/42?x=1")))
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://example.com/inbox/all")))
    }

    func testInvalidRegexMatchesNothingRatherThanEverything() {
        // A half-typed pattern must not suddenly apply the boost to every page.
        let match = BoostMatch(kind: .regex, pattern: "([unclosed")
        XCTAssertFalse(BoostMatcher.matches(match, url: url("https://example.com/")))
    }

    // MARK: Host normalisation

    func testNormalizedHost() {
        XCTAssertEqual(BoostMatcher.normalizedHost("HTTPS://Example.COM:443/path"), "example.com")
        XCTAssertEqual(BoostMatcher.normalizedHost("user:pass@example.com"), "example.com")
        XCTAssertEqual(BoostMatcher.normalizedHost("  .example.com.  "), "example.com")
        XCTAssertEqual(BoostMatcher.normalizedHost(""), "")
    }

    func testNormalizedHostKeepsIPv6Brackets() {
        // Stripping at the first colon would destroy an IPv6 literal.
        XCTAssertEqual(BoostMatcher.normalizedHost("[::1]"), "[::1]")
    }
}

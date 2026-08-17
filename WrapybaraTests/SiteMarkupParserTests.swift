import XCTest
@testable import Wrapybara

final class SiteMarkupParserTests: XCTestCase {

    private let base = URL(string: "https://example.com/app/")!

    // MARK: Attributes

    func testAttributeQuoting() {
        XCTAssertEqual(SiteMarkupParser.attribute("href", in: #"link href="/a.png" rel="icon""#),
                       "/a.png")
        XCTAssertEqual(SiteMarkupParser.attribute("href", in: "link href='/a.png'"), "/a.png")
        XCTAssertEqual(SiteMarkupParser.attribute("href", in: "link href=/a.png rel=icon"),
                       "/a.png")
    }

    func testAttributeNameIsCaseInsensitive() {
        XCTAssertEqual(SiteMarkupParser.attribute("href", in: #"link HREF="/a.png""#), "/a.png")
    }

    func testAttributeValueKeepsItsCase() {
        XCTAssertEqual(SiteMarkupParser.attribute("href", in: #"link href="/Icon.PNG""#),
                       "/Icon.PNG")
    }

    func testAttributeRequiresAWholeName() {
        // `data-rel` must not answer a request for `rel`.
        XCTAssertNil(SiteMarkupParser.attribute("rel", in: #"link data-rel="icon""#))
    }

    func testAttributeDecodesAmpersands() {
        XCTAssertEqual(SiteMarkupParser.attribute("href", in: #"link href="/i?a=1&amp;b=2""#),
                       "/i?a=1&b=2")
    }

    // MARK: Tags

    func testTagScanningRequiresADelimiterAfterTheName() {
        let tags = SiteMarkupParser.tags(named: "link", in: "<linkedin-widget x><link href=a>")
        XCTAssertEqual(tags.count, 1)
        XCTAssertTrue(tags[0].contains("href=a"))
    }

    func testTagIsTruncatedAtItsOwnCloseAngle() {
        let tags = SiteMarkupParser.tags(named: "link", in: "<link href=a><p>text</p>")
        XCTAssertEqual(tags, ["link href=a"])
    }

    // MARK: Sizes

    func testLargestEdge() {
        XCTAssertEqual(SiteMarkupParser.largestEdge(in: "16x16 32x32 180x180"), 180)
        XCTAssertEqual(SiteMarkupParser.largestEdge(in: "180X180"), 180)
        XCTAssertNil(SiteMarkupParser.largestEdge(in: "any"))
        XCTAssertNil(SiteMarkupParser.largestEdge(in: ""))
        XCTAssertNil(SiteMarkupParser.largestEdge(in: nil))
    }

    func testNonSquareSizesUseTheSmallerEdge() {
        // What matters for an icon is how much of a square it can fill.
        XCTAssertEqual(SiteMarkupParser.largestEdge(in: "1200x630"), 630)
    }

    // MARK: Whole pages

    func testParsesLinksAndManifest() {
        let html = """
        <html><head>
          <title>Example App &amp; Co — the best</title>
          <link rel="icon" href="/favicon-32.png" sizes="32x32" type="image/png">
          <link rel="apple-touch-icon" href="/touch.png" sizes="180x180">
          <link rel="manifest" href="/manifest.webmanifest">
          <meta name="theme-color" content="#101014">
          <meta property="og:image" content="https://cdn.example.com/card.png">
        </head><body><link rel="icon" href="/ignored.png"></body></html>
        """
        let page = SiteMarkupParser.parse(html: html, baseURL: base)

        XCTAssertEqual(page.title, "Example App & Co — the best")
        XCTAssertEqual(page.manifestURL?.absoluteString, "https://example.com/manifest.webmanifest")
        XCTAssertEqual(page.themeColor, "#101014")

        let sources = page.candidates.map(\.source)
        XCTAssertTrue(sources.contains(.appleTouchIcon))
        XCTAssertTrue(sources.contains(.linkIcon))
        XCTAssertTrue(sources.contains(.openGraphImage))
        // Parsing stops at </head>: a rel=icon in the body can't matter, and the body is
        // where the megabytes are.
        XCTAssertFalse(page.candidates.contains { $0.url.absoluteString.contains("ignored") })
    }

    func testRelativeHrefsResolveAgainstTheBase() {
        let page = SiteMarkupParser.parse(html: #"<link rel="icon" href="icon.png">"#, baseURL: base)
        XCTAssertEqual(page.candidates.first?.url.absoluteString,
                       "https://example.com/app/icon.png")
    }

    func testShortcutIconIsRecognised() {
        let page = SiteMarkupParser.parse(html: #"<link rel="shortcut icon" href="/f.ico">"#,
                                          baseURL: base)
        XCTAssertEqual(page.candidates.first?.source, .linkIcon)
    }

    func testMaskIconIsNotTreatedAsArtwork() {
        // A Safari pinned-tab mask is a monochrome silhouette; using it would make a black
        // square of an app icon.
        let page = SiteMarkupParser.parse(html: #"<link rel="mask-icon" href="/m.svg">"#,
                                          baseURL: base)
        XCTAssertTrue(page.candidates.isEmpty)
    }

    func testDangerousSchemesAreRejected() {
        let page = SiteMarkupParser.parse(
            html: #"<link rel="icon" href="javascript:alert(1)">"#, baseURL: base)
        XCTAssertTrue(page.candidates.isEmpty)
    }

    func testApplicationNameIsUsedWhenThereIsNoTitle() {
        let page = SiteMarkupParser.parse(
            html: #"<meta name="application-name" content="Widgets">"#, baseURL: base)
        XCTAssertEqual(page.title, "Widgets")
    }

    // MARK: Manifests

    func testParsesManifest() throws {
        let json = """
        {"name":"Example App","short_name":"Example","theme_color":"#101014",
         "icons":[{"src":"/i-192.png","sizes":"192x192","type":"image/png"},
                  {"src":"/i-512.png","sizes":"512x512"},
                  {"src":"/mask.png","sizes":"512x512","purpose":"monochrome"}]}
        """
        let manifestURL = URL(string: "https://example.com/manifest.webmanifest")!
        let manifest = try XCTUnwrap(SiteMarkupParser.parseManifest(Data(json.utf8),
                                                                   manifestURL: manifestURL))
        XCTAssertEqual(manifest.name, "Example App")
        XCTAssertEqual(manifest.shortName, "Example")
        XCTAssertEqual(manifest.themeColor, "#101014")
        // The monochrome entry is a mask, not artwork.
        XCTAssertEqual(manifest.candidates.count, 2)
        XCTAssertEqual(manifest.candidates.map(\.declaredEdge), [192, 512])
    }

    func testManifestToleratesSpecViolations() throws {
        // Manifests in the wild give `sizes` as a number and omit `src`; one bad entry must
        // not lose the good ones.
        let json = #"{"icons":[{"sizes":512},{"src":"/ok.png","sizes":256}]}"#
        let manifest = try XCTUnwrap(SiteMarkupParser.parseManifest(
            Data(json.utf8), manifestURL: URL(string: "https://example.com/m.json")!))
        XCTAssertEqual(manifest.candidates.count, 1)
        XCTAssertEqual(manifest.candidates.first?.declaredEdge, 256)
    }

    func testSizesAsANumber() {
        XCTAssertEqual(SiteMarkupParser.sizesString(NSNumber(value: 512)), "512x512")
        XCTAssertEqual(SiteMarkupParser.sizesString("48x48"), "48x48")
        XCTAssertNil(SiteMarkupParser.sizesString(nil))
    }

    func testGarbageManifestIsRejected() {
        XCTAssertNil(SiteMarkupParser.parseManifest(Data("not json".utf8),
                                                    manifestURL: base))
    }

    // MARK: Ranking

    func testRankingPrefersManifestThenTouchIconThenLink() {
        let candidates = [
            IconCandidate(url: URL(string: "https://a/1")!, source: .rootFavicon,
                          declaredEdge: nil, mimeType: nil),
            IconCandidate(url: URL(string: "https://a/2")!, source: .linkIcon,
                          declaredEdge: 32, mimeType: nil),
            IconCandidate(url: URL(string: "https://a/3")!, source: .appleTouchIcon,
                          declaredEdge: 180, mimeType: nil),
            IconCandidate(url: URL(string: "https://a/4")!, source: .webAppManifest,
                          declaredEdge: 192, mimeType: nil),
            IconCandidate(url: URL(string: "https://a/5")!, source: .openGraphImage,
                          declaredEdge: nil, mimeType: nil),
        ]
        XCTAssertEqual(IconCandidate.ranked(candidates).map(\.source),
                       [.webAppManifest, .appleTouchIcon, .linkIcon, .rootFavicon, .openGraphImage])
    }

    func testRankingBreaksTiesBySizeThenURLForStability() {
        let small = IconCandidate(url: URL(string: "https://a/small")!, source: .linkIcon,
                                  declaredEdge: 32, mimeType: nil)
        let large = IconCandidate(url: URL(string: "https://a/large")!, source: .linkIcon,
                                  declaredEdge: 512, mimeType: nil)
        XCTAssertEqual(IconCandidate.ranked([small, large]).first, large)
        XCTAssertEqual(IconCandidate.ranked([small, large]), IconCandidate.ranked([large, small]))
    }

    func testSVGIsExcluded() {
        // `NSImage` loads SVG only at its intrinsic size, which for a scalable icon is
        // often 16pt — rasterising that to 1024 looks worse than the monogram.
        let svg = IconCandidate(url: URL(string: "https://a/i.svg")!, source: .webAppManifest,
                                declaredEdge: 512, mimeType: nil)
        let byType = IconCandidate(url: URL(string: "https://a/i")!, source: .webAppManifest,
                                   declaredEdge: 512, mimeType: "image/svg+xml")
        XCTAssertFalse(svg.isUsableFormat)
        XCTAssertFalse(byType.isUsableFormat)
        XCTAssertTrue(IconCandidate.ranked([svg, byType]).isEmpty)
    }

    // MARK: Names

    func testCleanedNameStripsTaglines() {
        XCTAssertEqual(SiteIconFetcher.cleanedName("Proton Mail — Encrypted email"), "Proton Mail")
        XCTAssertEqual(SiteIconFetcher.cleanedName("Linear | Issue tracking"), "Linear")
        XCTAssertEqual(SiteIconFetcher.cleanedName("Figma - The design tool"), "Figma")
        XCTAssertEqual(SiteIconFetcher.cleanedName("  Notion  "), "Notion")
        XCTAssertNil(SiteIconFetcher.cleanedName(nil))
        XCTAssertNil(SiteIconFetcher.cleanedName("   "))
    }

    func testOverlyLongNamesAreRejected() {
        // A title that's really a sentence isn't a name.
        XCTAssertNil(SiteIconFetcher.cleanedName(String(repeating: "x", count: 60)))
    }

    // MARK: data: URLs

    func testDataURLPayloadDecodes() throws {
        let url = try XCTUnwrap(URL(string: "data:image/png;base64,aGVsbG8="))
        XCTAssertEqual(SiteIconFetcher.dataURLPayload(url), Data("hello".utf8))
    }

    func testNonBase64DataURLIsRejected() throws {
        let url = try XCTUnwrap(URL(string: "data:text/plain,hello"))
        XCTAssertNil(SiteIconFetcher.dataURLPayload(url))
    }
}

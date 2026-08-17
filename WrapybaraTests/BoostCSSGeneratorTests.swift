import XCTest
@testable import Wrapybara

final class BoostCSSGeneratorTests: XCTestCase {

    // MARK: The neutral case

    func testNeutralThemeGeneratesNothing() {
        // This is the property that makes "boost enabled but empty" free: no rules, so no
        // <style> element and nothing for the browser to recompute.
        XCTAssertEqual(BoostCSSGenerator.themeCSS(.neutral), "")
        XCTAssertNil(BoostCSSGenerator.filterValue(.neutral))
    }

    func testEmptyBoostGeneratesNoStylesheet() {
        XCTAssertEqual(BoostCSSGenerator.stylesheet(for: Boost()), "")
    }

    func testBoostIsEmptyWhenNothingIsSet() {
        XCTAssertTrue(Boost().isEmpty)
    }

    // MARK: Filters

    func testFilterOnlyIncludesMovedKnobs() {
        var theme = BoostTheme.neutral
        theme.contrast = 1.2
        XCTAssertEqual(BoostCSSGenerator.filterValue(theme), "contrast(1.2)")
    }

    func testFilterOrderIsFixed() {
        var theme = BoostTheme.neutral
        theme.saturation = 0.5
        theme.invert = 1
        theme.brightness = 1.1
        theme.hueRotate = 180
        XCTAssertEqual(BoostCSSGenerator.filterValue(theme),
                       "invert(1) hue-rotate(180deg) brightness(1.1) saturate(0.5)")
    }

    func testInvertAddsMediaCounterFilterWhenPreservingPhotos() {
        var theme = BoostTheme.neutral
        theme.invert = 1
        theme.preservesMediaWhenInverted = true
        let css = BoostCSSGenerator.themeCSS(theme)
        XCTAssertTrue(css.contains("html {\n  filter: invert(1);\n}"))
        XCTAssertTrue(css.contains("invert(1) hue-rotate(180deg)"))
        XCTAssertTrue(css.contains("img, video, canvas"))
    }

    func testInvertWithoutPreservationHasNoCounterFilter() {
        var theme = BoostTheme.neutral
        theme.invert = 1
        theme.preservesMediaWhenInverted = false
        let css = BoostCSSGenerator.themeCSS(theme)
        XCTAssertFalse(css.contains("hue-rotate(180deg)"))
    }

    // MARK: Colours

    func testSurfaceReachOnlyTouchesHtmlAndBody() {
        var theme = BoostTheme.neutral
        theme.backgroundColor = "#101014"
        let css = BoostCSSGenerator.themeCSS(theme)
        XCTAssertTrue(css.contains("html, body {\n  background-color: #101014 !important;\n}"))
        XCTAssertFalse(css.contains("background-color: transparent"))
    }

    func testEverythingReachClearsBackgroundColorOnly() {
        var theme = BoostTheme.neutral
        theme.backgroundColor = "#101014"
        theme.colorReach = .everything
        let css = BoostCSSGenerator.themeCSS(theme)
        XCTAssertTrue(css.contains("background-color: transparent !important"))
        // The `background` shorthand would drop background *images* too, which sites use
        // for logos and icons.
        XCTAssertFalse(css.contains("background: transparent"))
        XCTAssertFalse(css.contains("background-image: none"))
    }

    func testLinkRuleComesAfterTheBlanketTextRule() {
        var theme = BoostTheme.neutral
        theme.textColor = "#eeeeee"
        theme.linkColor = "#4da3ff"
        theme.colorReach = .everything
        let css = BoostCSSGenerator.themeCSS(theme)
        guard let textIndex = css.range(of: "color: #eeeeee !important")?.lowerBound,
              let linkIndex = css.range(of: "a, a:visited, a:hover")?.lowerBound else {
            return XCTFail("expected both rules")
        }
        // CSS is order-sensitive on equal specificity, so links have to be emitted last
        // or the blanket rule would swallow them.
        XCTAssertLessThan(textIndex, linkIndex)
    }

    // MARK: Colour sanitising

    func testColorShorthandIsExpandedAndLowercased() {
        XCTAssertEqual(BoostCSSGenerator.sanitizedColor("#ABC"), "#aabbcc")
        XCTAssertEqual(BoostCSSGenerator.sanitizedColor("ABCD"), "#aabbccdd")
        XCTAssertEqual(BoostCSSGenerator.sanitizedColor("#11223344"), "#11223344")
    }

    func testUnparseableColorIsDropped() {
        for bad in ["", "  ", "red", "#12345", "#GGGGGG", "rgb(1,2,3)", "#fff; } body {"] {
            XCTAssertNil(BoostCSSGenerator.sanitizedColor(bad), "\(bad) should be rejected")
        }
    }

    func testUnparseableColorEmitsNoRule() {
        var theme = BoostTheme.neutral
        theme.backgroundColor = "not a colour"
        XCTAssertEqual(BoostCSSGenerator.themeCSS(theme), "")
    }

    // MARK: Fonts

    func testFontStackIsPassedThroughAndExcludesIconFonts() {
        var theme = BoostTheme.neutral
        theme.fontFamily = #""Iowan Old Style", Georgia, serif"#
        let css = BoostCSSGenerator.themeCSS(theme)
        XCTAssertTrue(css.contains(#"font-family: "Iowan Old Style", Georgia, serif !important"#))
        // Replacing the font on an icon-font element turns every glyph into tofu.
        XCTAssertTrue(css.contains(#":not([class*="icon"])"#))
        XCTAssertTrue(css.contains(":not(code)"))
    }

    func testFontStackWithDeclarationBreakingCharactersIsRejected() {
        for bad in ["Helvetica; } body { display:none", "Helvetica /* x */", "A\nB"] {
            XCTAssertNil(BoostCSSGenerator.sanitizedFontStack(bad), "\(bad) should be rejected")
        }
    }

    func testFontScaleUsesRootPercentage() {
        var theme = BoostTheme.neutral
        theme.fontScale = 1.25
        XCTAssertTrue(BoostCSSGenerator.themeCSS(theme)
            .contains(":root {\n  font-size: 125% !important;\n}"))
    }

    func testTextTransformNoneEmitsNothing() {
        XCTAssertNil(BoostTheme.TextTransform.none.cssValue)
        var theme = BoostTheme.neutral
        theme.textTransform = .none
        XCTAssertEqual(BoostCSSGenerator.themeCSS(theme), "")
    }

    // MARK: Zap

    func testZapCSSJoinsSelectorsIntoOneRule() {
        let css = BoostCSSGenerator.zapCSS(["#ads", ".promo-banner"])
        XCTAssertTrue(css.contains("#ads,\n.promo-banner {"))
        XCTAssertTrue(css.contains("display: none !important;"))
    }

    func testZapCSSIsEmptyWithoutSelectors() {
        XCTAssertEqual(BoostCSSGenerator.zapCSS([]), "")
        XCTAssertEqual(BoostCSSGenerator.zapCSS(["", "   "]), "")
    }

    func testUnsafeSelectorsAreDroppedNotEscaped() {
        // A selector carrying a brace would end the rule and change the meaning of every
        // rule after it. Escaping it would produce something that no longer selects what
        // the user picked, so it's dropped instead.
        let css = BoostCSSGenerator.zapCSS(["#ok", "} body { display: none", ".x /* y */", "a;b"])
        XCTAssertTrue(css.contains("#ok"))
        XCTAssertFalse(css.contains("body {"))
        XCTAssertFalse(css.contains(".x"))
        XCTAssertFalse(css.contains(";b"))
    }

    func testSelectorSafety() {
        XCTAssertTrue(BoostCSSGenerator.isSafeSelector("div.header > a:nth-of-type(2)"))
        XCTAssertTrue(BoostCSSGenerator.isSafeSelector(#"[data-test="x"]"#))
        XCTAssertFalse(BoostCSSGenerator.isSafeSelector("a,"))
        XCTAssertFalse(BoostCSSGenerator.isSafeSelector(",a"))
        XCTAssertFalse(BoostCSSGenerator.isSafeSelector("a\nb"))
        XCTAssertFalse(BoostCSSGenerator.isSafeSelector("<script>"))
    }

    // MARK: Composition

    func testCustomCSSComesLastSoItWins() {
        var boost = Boost(name: "Test")
        boost.theme.backgroundColor = "#000000"
        boost.zapSelectors = ["#ads"]
        boost.css = ".mine { color: red }"
        let css = BoostCSSGenerator.stylesheet(for: boost)
        guard let themeIndex = css.range(of: "background-color")?.lowerBound,
              let zapIndex = css.range(of: "#ads")?.lowerBound,
              let customIndex = css.range(of: ".mine")?.lowerBound else {
            return XCTFail("expected all three blocks")
        }
        XCTAssertLessThan(themeIndex, zapIndex)
        XCTAssertLessThan(zapIndex, customIndex)
    }

    func testBoostNameCannotCloseItsOwnComment() {
        var boost = Boost(name: "evil */ body { display: none } /*")
        boost.css = "a { color: red }"
        let css = BoostCSSGenerator.stylesheet(for: boost)
        // The name is written into a comment header; a `*/` inside it would escape it and
        // turn the rest of the name into live CSS. So the header must contain exactly one
        // comment terminator — the one that closes it.
        let header = css.split(separator: "\n").first.map(String.init) ?? ""
        XCTAssertTrue(header.hasPrefix("/*"))
        XCTAssertTrue(header.hasSuffix("*/"))
        XCTAssertEqual(header.components(separatedBy: "*/").count - 1, 1)
    }

    func testMultipleBoostsAreConcatenatedInOrder() {
        var first = Boost(name: "First")
        first.css = ".a {}"
        var second = Boost(name: "Second")
        second.css = ".b {}"
        let css = BoostCSSGenerator.stylesheet(for: [first, second])
        guard let a = css.range(of: ".a {}")?.lowerBound,
              let b = css.range(of: ".b {}")?.lowerBound else { return XCTFail("expected both") }
        XCTAssertLessThan(a, b)
    }

    func testEmptyBoostsAreSkippedInCombinedStylesheet() {
        var real = Boost(name: "Real")
        real.css = ".a {}"
        XCTAssertEqual(BoostCSSGenerator.stylesheet(for: [Boost(), real, Boost()]),
                       BoostCSSGenerator.stylesheet(for: real))
    }

    // MARK: Numbers

    func testNumberFormattingIsStableAndLocaleFree() {
        XCTAssertEqual(BoostCSSGenerator.number(1), "1")
        XCTAssertEqual(BoostCSSGenerator.number(2.0), "2")
        XCTAssertEqual(BoostCSSGenerator.number(1.5), "1.5")
        XCTAssertEqual(BoostCSSGenerator.number(0.25), "0.25")
        XCTAssertEqual(BoostCSSGenerator.number(-180), "-180")
        // A comma decimal separator would be invalid CSS.
        XCTAssertFalse(BoostCSSGenerator.number(1.5).contains(","))
    }

    func testNonFiniteNumberDoesNotEmitNaN() {
        XCTAssertEqual(BoostCSSGenerator.number(.nan), "0")
        XCTAssertEqual(BoostCSSGenerator.number(.infinity), "0")
    }

    // MARK: Determinism

    func testGenerationIsDeterministic() {
        var boost = Boost(name: "Kitchen Sink")
        boost.theme = BoostTheme(backgroundColor: "#101014", textColor: "#eeeeee",
                                 linkColor: "#4da3ff", accentColor: "#8b5a2b",
                                 colorReach: .everything, fontFamily: "Georgia, serif",
                                 monospaceFontFamily: "Menlo", fontScale: 1.1,
                                 textTransform: .capitalize, lineHeightScale: 1.2,
                                 readableWidth: 720, brightness: 1.05, contrast: 1.1,
                                 saturation: 0.9, hueRotate: 12, invert: 0.2, grayscale: 0.1,
                                 preservesMediaWhenInverted: true, cornerRadius: 8,
                                 hidesImages: false)
        boost.zapSelectors = ["#ads", ".promo"]
        boost.css = ".mine { color: red }"
        XCTAssertEqual(BoostCSSGenerator.stylesheet(for: boost),
                       BoostCSSGenerator.stylesheet(for: boost))
    }
}

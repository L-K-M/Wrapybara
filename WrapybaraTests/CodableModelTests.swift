import XCTest
@testable import Wrapybara

/// The stored formats. These matter more than most tests here: a wrap config is a file
/// on disk *and* a copy baked into every generated app, so a decoding regression would
/// orphan apps built by an earlier version.
final class CodableModelTests: XCTestCase {

    private let encoder = JSONFileStore.encoder
    private let decoder = JSONFileStore.decoder

    /// A whole-second date.
    ///
    /// The store encodes dates as ISO-8601, which carries no sub-second component — so a
    /// `Date()` taken from the clock is *not* equal to itself after a round trip. Using a
    /// truncated date keeps these tests about the model rather than about float precision.
    /// (Nothing in the app depends on finer resolution: these timestamps order edits and
    /// pick the newer of two configurations.)
    private let fixedDate = Date(timeIntervalSince1970: 1_700_000_000)

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        try decoder.decode(T.self, from: try encoder.encode(value))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try decoder.decode(type, from: Data(json.utf8))
    }

    // MARK: Round trips

    func testWrapRoundTrips() throws {
        var wrap = Wrap(name: "Claude",
                        homeURL: URL(string: "https://claude.ai")!,
                        bundleIdentifier: "com.wrapybara.site.ai.claude",
                        createdAt: fixedDate, updatedAt: fixedDate)
        wrap.behavior.chrome = .titleBarOnly
        wrap.behavior.additionalInAppHosts = ["accounts.example.com"]
        wrap.boosts = [Boost(name: "Dark", theme: BoostTheme(backgroundColor: "#101014"),
                             createdAt: fixedDate, updatedAt: fixedDate)]
        wrap.installedAppPath = "/Applications/Claude.app"

        let decoded = try roundTrip(wrap)
        XCTAssertEqual(decoded, wrap)
    }

    func testBoostRoundTrips() throws {
        var boost = Boost(name: "Zap ads", match: .domain("example.com"),
                          createdAt: fixedDate, updatedAt: fixedDate)
        boost.zapSelectors = ["#ads", ".promo"]
        boost.css = "body { color: red }"
        boost.javaScript = "console.log('hi')"
        boost.isJavaScriptTrusted = true
        XCTAssertEqual(try roundTrip(boost), boost)
    }

    func testWrapLibraryRoundTrips() throws {
        let shared = Boost(name: "Shared", createdAt: fixedDate, updatedAt: fixedDate)
        var wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x",
                        createdAt: fixedDate, updatedAt: fixedDate)
        wrap.enabledSharedBoostIDs = [shared.id]
        let library = WrapLibrary(wraps: [wrap], sharedBoosts: [shared])
        XCTAssertEqual(try roundTrip(library), library)
    }

    // MARK: Missing keys become defaults

    func testMinimalWrapDecodes() throws {
        // Every key may be absent — that is what lets the format gain a property without
        // invalidating files an older build wrote.
        let wrap = try decode(Wrap.self, #"{"homeURL":"https://example.com"}"#)
        XCTAssertEqual(wrap.homeURL.absoluteString, "https://example.com")
        XCTAssertEqual(wrap.behavior, .default)
        XCTAssertTrue(wrap.boosts.isEmpty)
        XCTAssertNil(wrap.installedAppPath)
    }

    func testMinimalBoostDecodes() throws {
        let boost = try decode(Boost.self, "{}")
        XCTAssertEqual(boost.match, .everywhere)
        XCTAssertEqual(boost.theme, .neutral)
        XCTAssertTrue(boost.isEnabled)
    }

    func testUnknownKeysAreIgnored() throws {
        let boost = try decode(Boost.self, #"{"name":"X","somethingNew":42}"#)
        XCTAssertEqual(boost.name, "X")
    }

    func testWrongTypedValueFallsBackToTheDefaultForThatFieldOnly() throws {
        // These files are hand-editable. One mistyped value should cost that field, not the
        // rest of the user's work.
        let behavior = try decode(WrapBehavior.self,
                                  #"{"pageZoom":"not a number","allowsNativeTabs":false}"#)
        XCTAssertEqual(behavior.pageZoom, 1)
        XCTAssertFalse(behavior.allowsNativeTabs)
    }

    func testUnknownEnumValueFallsBackToTheDefault() throws {
        let behavior = try decode(WrapBehavior.self, #"{"chrome":"hologram"}"#)
        XCTAssertEqual(behavior.chrome, .toolbar)
    }

    // MARK: The JavaScript trust flag

    func testDecodedBoostWithoutTheTrustFlagIsNotTrusted() throws {
        // A file that predates the flag — or one hand-edited to drop it — must not silently
        // gain permission to run its script inside the user's session.
        let boost = try decode(Boost.self, #"{"javaScript":"alert(1)"}"#)
        XCTAssertFalse(boost.isJavaScriptTrusted)
        XCTAssertFalse(boost.hasRunnableJavaScript)
        XCTAssertTrue(boost.hasUntrustedJavaScript)
    }

    func testTrustSurvivesARoundTripForABoostTheUserWrote() throws {
        var boost = Boost(name: "Mine", createdAt: fixedDate, updatedAt: fixedDate)
        boost.javaScript = "console.log(1)"
        boost.isJavaScriptTrusted = true
        XCTAssertTrue(try roundTrip(boost).hasRunnableJavaScript)
    }

    func testUntrustedScriptIsNotConsideredContent() throws {
        var boost = Boost(name: "Imported")
        boost.javaScript = "alert(1)"
        boost.isJavaScriptTrusted = false
        // It has *something*, but nothing that will run, so it generates nothing.
        XCTAssertTrue(boost.isEmpty)
        XCTAssertEqual(BoostCSSGenerator.stylesheet(for: boost), "")
    }

    // MARK: WrapConfiguration

    func testResolvedConfigurationMovesBoostsOutOfTheWrap() {
        var wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        wrap.boosts = [Boost(name: "Local")]
        wrap.enabledSharedBoostIDs = [UUID()]
        let configuration = WrapConfiguration.resolved(wrap, boosts: wrap.boosts,
                                                       generatedBy: "test")
        // Exactly one authoritative list, so there's no question which one the runtime obeys.
        XCTAssertTrue(configuration.wrap.boosts.isEmpty)
        XCTAssertTrue(configuration.wrap.enabledSharedBoostIDs.isEmpty)
        XCTAssertEqual(configuration.boosts.count, 1)
    }

    func testConfigurationRequiresAWrap() {
        XCTAssertThrowsError(try decode(WrapConfiguration.self, #"{"boosts":[]}"#))
    }

    func testNewerPrefersTheLaterGeneratedCopy() {
        let wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        let old = WrapConfiguration(wrap: wrap, boosts: [], generatedBy: "old",
                                    generatedAt: Date(timeIntervalSince1970: 100))
        let new = WrapConfiguration(wrap: wrap, boosts: [], generatedBy: "new",
                                    generatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(WrapConfiguration.newer(bundled: old, stored: new)?.generatedBy, "new")
        // And the other direction: rebuilding the app beats a stale store entry.
        XCTAssertEqual(WrapConfiguration.newer(bundled: new, stored: old)?.generatedBy, "new")
    }

    func testNewerHandlesMissingCopies() {
        let wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        let only = WrapConfiguration(wrap: wrap, boosts: [], generatedBy: "only")
        XCTAssertEqual(WrapConfiguration.newer(bundled: only, stored: nil)?.generatedBy, "only")
        XCTAssertEqual(WrapConfiguration.newer(bundled: nil, stored: only)?.generatedBy, "only")
        XCTAssertNil(WrapConfiguration.newer(bundled: nil, stored: nil))
    }

    func testFutureFormatIsRefusedRatherThanHalfUnderstood() {
        let wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        var future = WrapConfiguration(wrap: wrap, boosts: [], generatedBy: "future")
        future.formatVersion = WrapConfiguration.currentFormatVersion + 1
        XCTAssertFalse(future.isReadable)
        XCTAssertNil(WrapConfiguration.newer(bundled: future, stored: nil))
    }

    func testConfigurationFiltersBoostsByURLAndEnablement() {
        let wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        var matching = Boost(name: "Matches", match: .domain("a.test"))
        matching.css = "body{}"
        var elsewhere = Boost(name: "Elsewhere", match: .domain("b.test"))
        elsewhere.css = "body{}"
        var disabled = Boost(name: "Disabled", match: .everywhere)
        disabled.css = "body{}"
        disabled.isEnabled = false
        let empty = Boost(name: "Empty", match: .everywhere)

        let configuration = WrapConfiguration(
            wrap: wrap, boosts: [matching, elsewhere, disabled, empty], generatedBy: "test")
        let applied = configuration.boosts(matching: URL(string: "https://a.test/x")!)
        XCTAssertEqual(applied.map(\.name), ["Matches"])
    }

    // MARK: Library resolution

    func testResolvedBoostsPutLocalBoostsFirst() {
        // Later rules win in CSS, so a shared baseline must not override the per-wrap
        // correction the user wrote specifically to escape it.
        let shared = Boost(name: "Shared")
        let local = Boost(name: "Local")
        var wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        wrap.boosts = [local]
        wrap.enabledSharedBoostIDs = [shared.id]
        let library = WrapLibrary(wraps: [wrap], sharedBoosts: [shared])
        XCTAssertEqual(library.resolvedBoosts(for: wrap).map(\.name), ["Local", "Shared"])
    }

    func testDisabledSharedBoostsAreNotResolved() {
        let shared = Boost(name: "Shared")
        let wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        let library = WrapLibrary(wraps: [wrap], sharedBoosts: [shared])
        XCTAssertTrue(library.resolvedBoosts(for: wrap).isEmpty)
    }

    // MARK: Staleness

    func testStaleRuntimeDetection() {
        var wrap = Wrap(name: "A", homeURL: URL(string: "https://a.test")!, bundleIdentifier: "x")
        // Not built: nothing to be stale.
        XCTAssertFalse(wrap.hasStaleRuntime(currentVersion: "1.0.0"))

        wrap.installedAppPath = "/Applications/A.app"
        // Built but with no recorded version: assume stale.
        XCTAssertTrue(wrap.hasStaleRuntime(currentVersion: "1.0.0"))

        wrap.installedRuntimeVersion = "1.0.0"
        XCTAssertFalse(wrap.hasStaleRuntime(currentVersion: "1.0.0"))
        XCTAssertTrue(wrap.hasStaleRuntime(currentVersion: "1.1.0"))
    }

    // MARK: Icons

    func testMonogramInitials() {
        XCTAssertEqual(WrapIcon.initials(for: "Proton Mail"), "PM")
        XCTAssertEqual(WrapIcon.initials(for: "Claude"), "CL")
        XCTAssertEqual(WrapIcon.initials(for: "top-drawer"), "TD")
        XCTAssertEqual(WrapIcon.initials(for: "a.b.c"), "AB")
        XCTAssertEqual(WrapIcon.initials(for: ""), "")
        XCTAssertEqual(WrapIcon.initials(for: "   "), "")
    }

    func testMonogramTintIsStableAcrossProcesses() {
        // `String.hashValue` is seeded per process; using it would repaint every icon on
        // relaunch, which is why the tint uses its own hash.
        XCTAssertEqual(WrapIcon.tintHex(for: "Claude"), WrapIcon.tintHex(for: "claude"))
        XCTAssertTrue(WrapIcon.palette.contains(WrapIcon.tintHex(for: "Anything")))
        XCTAssertEqual(WrapIcon.tintHex(for: ""), WrapIcon.defaultTintHex)
    }

    // MARK: Icon plates

    func testIconWithAPlateRoundTrips() throws {
        var icon = WrapIcon(origin: .pickedFile,
                            sourceURL: URL(string: "file:///tmp/artwork.png"),
                            tintHex: "#2C5F8A", monogram: "A")
        icon.plate = IconPlate(colorHex: "#CC4400", pattern: .bricks)
        XCTAssertEqual(try roundTrip(icon), icon)
    }

    func testIconWrittenBeforePlatesDecodesToAutomatic() throws {
        // Libraries and baked-in configs from before plates were editable have no
        // `plate` key; nil *is* the automatic behaviour they used to get.
        // `##` delimiters, not `#`: the JSON carries a hex colour, and a value that
        // starts with `#` puts a `"#` — the `#"…"#` terminator — inside a
        // single-hash raw string. This line broke CI for every commit after it
        // landed with "'B' is not a valid digit in integer literal", because
        // `…tintHex":"` is where Swift thought the string ended.
        let icon = try decode(WrapIcon.self,
                              ##"{"origin":"monogram","tintHex":"#8B5A2B","monogram":"WB"}"##)
        XCTAssertNil(icon.plate)
        let resolved = IconPlate.resolved(for: icon)
        XCTAssertEqual(resolved.colorHex, "#8B5A2B")
        XCTAssertNil(resolved.pattern)
    }

    func testAChosenPlateWinsOverTheTint() {
        var icon = WrapIcon(origin: .monogram, tintHex: "#2C5F8A", monogram: "WB")
        icon.plate = IconPlate(colorHex: "#CC4400", pattern: .dots)
        XCTAssertEqual(IconPlate.resolved(for: icon),
                       IconPlate(colorHex: "#CC4400", pattern: .dots))
    }

    func testABadPlateColourCostsOnlyThatField() throws {
        // Hand-editable files: one mistyped value degrades to the default for that
        // field, and the pattern choice survives.
        let plate = try decode(IconPlate.self, #"{"colorHex":"octarine","pattern":"weave"}"#)
        XCTAssertEqual(plate.colorHex, WrapIcon.defaultTintHex)
        XCTAssertEqual(plate.pattern, .weave)
    }

    func testAnUnknownPatternNameDropsToTheGradient() throws {
        let plate = try decode(IconPlate.self, #"{"colorHex":"#CC4400","pattern":"houndstooth"}"#)
        XCTAssertNil(plate.pattern)
    }
}

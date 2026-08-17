import AppKit
import XCTest
@testable import Wrapybara

/// `InfoPlistBuilder`, `IcnsWriter` and `CodeSigner`'s parsing — the parts of generating
/// an app that can be checked without actually writing one.
final class BundleWritingTests: XCTestCase {

    private func wrap(_ urlString: String = "https://claude.ai", name: String = "Claude") -> Wrap {
        Wrap(name: name,
             homeURL: URL(string: urlString)!,
             bundleIdentifier: "com.wrapybara.site.ai.claude")
    }

    private func plist(_ wrap: Wrap) -> [String: Any] {
        InfoPlistBuilder.plist(for: wrap, executableName: "Claude", version: "1.2.0",
                              buildNumber: "34", generatedBy: "Wrapybara 1.2.0")
    }

    // MARK: Required keys

    func testCarriesTheKeysLaunchServicesNeeds() {
        let info = plist(wrap())
        XCTAssertEqual(info["CFBundleIdentifier"] as? String, "com.wrapybara.site.ai.claude")
        XCTAssertEqual(info["CFBundleExecutable"] as? String, "Claude")
        XCTAssertEqual(info["CFBundlePackageType"] as? String, "APPL")
        XCTAssertEqual(info["CFBundleShortVersionString"] as? String, "1.2.0")
        XCTAssertEqual(info["CFBundleVersion"] as? String, "34")
        XCTAssertEqual(info["NSPrincipalClass"] as? String, "NSApplication")
        XCTAssertEqual(info["NSHighResolutionCapable"] as? Bool, true)
        XCTAssertEqual(info["LSMinimumSystemVersion"] as? String, "13.0")
    }

    func testCarriesTheKeysTheRuntimeReads() {
        let subject = wrap()
        let info = plist(subject)
        XCTAssertEqual(info[InfoPlistBuilder.Key.wrapIdentifier] as? String, subject.id.uuidString)
        XCTAssertEqual(info[InfoPlistBuilder.Key.configurationFile] as? String,
                       InfoPlistBuilder.configurationFileName)
        XCTAssertEqual(info[InfoPlistBuilder.Key.homeURL] as? String, "https://claude.ai")
    }

    func testMediaUsageStringsNameTheSite() {
        // macOS kills a process that triggers a TCC prompt with no usage string, and the
        // user reads this text in the dialog.
        let info = plist(wrap())
        let camera = info["NSCameraUsageDescription"] as? String ?? ""
        XCTAssertTrue(camera.contains("claude.ai"))
        XCTAssertFalse((info["NSMicrophoneUsageDescription"] as? String ?? "").isEmpty)
    }

    func testBundleNameIsCappedButDisplayNameIsNot() {
        // `CFBundleName` is documented as 15 characters; the long form belongs in
        // `CFBundleDisplayName`, which is what macOS actually shows.
        let long = wrap(name: "A Very Long Application Name Indeed")
        let info = plist(long)
        XCTAssertEqual((info["CFBundleName"] as? String)?.count, 15)
        XCTAssertEqual(info["CFBundleDisplayName"] as? String, long.name)
    }

    // MARK: App Transport Security

    func testHTTPSNeedsNoTransportSecurityException() {
        XCTAssertNil(plist(wrap())["NSAppTransportSecurity"])
        XCTAssertNil(InfoPlistBuilder.appTransportSecurity(for: URL(string: "https://x.test")!))
    }

    func testPlainHTTPGetsAScopedException() {
        // Refusing to wrap an intranet tool on a plain-HTTP host would be an odd hill to
        // die on; the exception is scoped to that one host.
        let info = plist(wrap("http://intranet.local/app", name: "Intranet"))
        let ats = info["NSAppTransportSecurity"] as? [String: Any]
        let domains = ats?["NSExceptionDomains"] as? [String: Any]
        XCTAssertNotNil(domains?["intranet.local"])
        XCTAssertNil(ats?["NSAllowsArbitraryLoads"])
    }

    // MARK: Serialisation

    func testPlistSerialisesAsXML() throws {
        // Everything in the dictionary has to be a property-list type, or writing the
        // bundle fails at the last step.
        let data = try PropertyListSerialization.data(fromPropertyList: plist(wrap()),
                                                      format: .xml, options: 0)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(text.contains("CFBundleIdentifier"))
    }

    // MARK: ICNS

    func testIcnsHasTheRightContainerHeader() throws {
        let image = IconComposer.monogram("WB", plateColor: .systemBrown)
        let data = try IcnsWriter.data(for: image)

        XCTAssertGreaterThan(data.count, 8)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "icns")
        // The length field covers the whole file, header included.
        let declared = data.subdata(in: 4..<8).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        XCTAssertEqual(Int(declared), data.count)
    }

    func testIcnsContainsEveryDeclaredElementType() throws {
        let image = IconComposer.monogram("WB", plateColor: .systemBrown)
        let data = try IcnsWriter.data(for: image)
        let text = String(decoding: data, as: UTF8.self)
        for element in IcnsWriter.elements {
            XCTAssertTrue(text.contains(element.type),
                          "\(element.type) missing — Retina slots matter for the Dock")
        }
    }

    func testIcnsIncludesRetinaSlots() {
        // Omitting the @2x set makes an icon that looks soft in the Dock, which is exactly
        // the "not a real Mac app" tell this project is about.
        let types = Set(IcnsWriter.elements.map(\.type))
        for retina in ["ic11", "ic12", "ic13", "ic14", "ic10"] {
            XCTAssertTrue(types.contains(retina))
        }
    }

    func testRenderingProducesTheRequestedPixelSize() throws {
        // A source with only a small representation (a 32px favicon) must not hand back its
        // own size — that would produce a mismatched element.
        let small = NSImage(size: NSSize(width: 32, height: 32), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = try XCTUnwrap(IcnsWriter.pngData(from: small, pixels: 512))
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 512)
        XCTAssertEqual(rep.pixelsHigh, 512)
    }

    // MARK: Icon composition

    func testComposedIconIsCanvasSized() {
        let artwork = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.blue.setFill()
            rect.fill()
            return true
        }
        let composed = IconComposer.compose(artwork: artwork, style: .plate,
                                            plateColor: .systemBrown)
        XCTAssertEqual(composed.size.width, IconComposer.canvas)
        XCTAssertEqual(composed.size.height, IconComposer.canvas)
    }

    func testPlateLeavesAMarginSoTheDockTileMatchesOtherApps() {
        // 824 of 1024 is Apple's macOS app-icon grid; a full-bleed square reads as foreign.
        XCTAssertLessThan(IconComposer.plateEdge, IconComposer.canvas)
        XCTAssertEqual(IconComposer.plateEdge, 824)
    }

    func testPlateColorFallsBackForAnUnreadableTint() {
        var icon = WrapIcon()
        icon.tintHex = "not a colour"
        XCTAssertNotNil(IconComposer.plateColor(for: icon))
    }

    // MARK: Signing identities

    func testParsesSecurityFindIdentityOutput() {
        let output = """
          1) A1B2C3D4E5F6 "Developer ID Application: Someone (TEAM123)"
          2) 0102030405060708 "Apple Development: Someone Else (TEAM123)"
             2 valid identities found
        """
        let identities = CodeSigner.parseIdentities(output)
        XCTAssertEqual(identities.count, 2)
        XCTAssertEqual(identities[0].hash, "A1B2C3D4E5F6")
        XCTAssertEqual(identities[0].name, "Developer ID Application: Someone (TEAM123)")
    }

    func testIdentityParsingSkipsTheSummaryLine() {
        XCTAssertTrue(CodeSigner.parseIdentities("     0 valid identities found").isEmpty)
        XCTAssertTrue(CodeSigner.parseIdentities("").isEmpty)
    }

    func testAdHocIsTheDefaultIdentity() {
        XCTAssertEqual(CodeSigner.adHocIdentity, "-")
    }
}

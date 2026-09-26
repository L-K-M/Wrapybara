import Foundation
import XCTest
@testable import Wrapybara

final class AndroidExportPlanTests: XCTestCase {
    private func configuration(name: String = "Example", address: String = "https://example.com") -> WrapConfiguration {
        let wrap = Wrap(name: name, homeURL: URL(string: address)!)
        return .resolved(wrap, boosts: [], generatedBy: "test")
    }

    func testPackageIdentitySurvivesRenamingAndDiffersBetweenWraps() throws {
        var config = configuration()
        let first = try AndroidExportPlan(configuration: config, versionCode: 1)
        config.wrap.name = "Renamed"
        config.wrap.bundleIdentifier = "org.example.mac"
        let renamed = try AndroidExportPlan(configuration: config, versionCode: 2)
        XCTAssertEqual(first.packageIdentifier, renamed.packageIdentifier)
        XCTAssertNotEqual(first.packageIdentifier,
                          AndroidExportPlan.packageIdentifier(for: UUID()))
        XCTAssertNotNil(first.packageIdentifier.range(
            of: "^com\\.wrapybara\\.site\\.w[a-f0-9]{32}$", options: .regularExpression))
        XCTAssertTrue(renamed.manifest.contains("android:versionCode=\"2\""))
    }

    func testRejectsAddressesThatCannotBeWrapped() {
        for address in ["file:///tmp/page.html", "javascript:alert(1)", "about:blank",
                        "https://user:password@example.com"] {
            XCTAssertThrowsError(try AndroidExportPlan(configuration: configuration(address: address),
                                                       versionCode: 1), address)
        }
        XCTAssertThrowsError(try AndroidExportPlan(configuration: configuration(name: " \n"),
                                                   versionCode: 1))
    }

    func testCleartextOnlyForAnHTTPHomePage() throws {
        let secure = try AndroidExportPlan(configuration: configuration(), versionCode: 1)
        XCTAssertTrue(secure.manifest.contains("android:usesCleartextTraffic=\"false\""))
        let plain = try AndroidExportPlan(configuration: configuration(address: "http://nas.local:5000"),
                                          versionCode: 1)
        XCTAssertTrue(plain.manifest.contains("android:usesCleartextTraffic=\"true\""))
    }

    func testVersionBounds() {
        XCTAssertNoThrow(try AndroidExportPlan(configuration: configuration(),
                                               versionCode: AndroidExportPlan.maximumVersionCode))
        for version in [0, -1, AndroidExportPlan.maximumVersionCode + 1] {
            XCTAssertThrowsError(try AndroidExportPlan(configuration: configuration(), versionCode: version))
        }
    }

    func testRuntimeConfigurationContainsOnlySupportedSettings() throws {
        var config = configuration()
        config.wrap.behavior.additionalInAppHosts = [" HTTPS://Login.Example.org/path ", ""]
        config.wrap.behavior.externalLinks = .openInNewTab
        config.wrap.behavior.restoresSession = false
        let plan = try AndroidExportPlan(configuration: config, versionCode: 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: plan.runtimeConfiguration()) as? [String: Any])
        XCTAssertEqual(json["allowedDomains"] as? [String], ["example.com", "login.example.org"])
        XCTAssertEqual(json["openExternalLinksInBrowser"] as? Bool, false)
        XCTAssertEqual(json["restoreLastPage"] as? Bool, false)
        XCTAssertNil(json["installedAppPath"])
        XCTAssertNil(json["boosts"])
    }

    func testResourceEscapesXMLAndAndroidStringSyntax() throws {
        let plan = try AndroidExportPlan(configuration: configuration(name: "@O'Reilly & <\"Site\"> \\ %s"),
                                         versionCode: 1)
        XCTAssertTrue(plan.stringResources.contains("&amp;"))
        XCTAssertTrue(plan.stringResources.contains("&lt;"))
        XCTAssertTrue(plan.stringResources.contains("\\'"))
        XCTAssertTrue(plan.stringResources.contains("\\\""))
        XCTAssertTrue(plan.stringResources.contains("formatted=\"false\""))
    }

    func testRuntimeSourcesShipWithBuilder() throws {
        for name in ["AndroidSiteActivity", "AndroidNavigationPolicy"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "java.txt"))
            XCTAssertTrue(try String(contentsOf: url).contains("package com.wrapybara.runtime;"))
        }
    }
}

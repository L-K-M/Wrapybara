import Foundation
import XCTest
@testable import Wrapybara

final class AndroidAPKExporterTests: XCTestCase {
    func testMissingSigningKeyCannotBecomeANewIdentity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrap = Wrap(name: "Test", homeURL: URL(string: "https://example.com")!)
        let records = directory.appendingPathComponent("AndroidExports")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let record = records.appendingPathComponent(AndroidExportPlan.packageIdentifier(for: wrap.id))
            .appendingPathExtension("json")
        try Data(#"{"versionCode":3}"#.utf8).write(to: record)

        // Reject before invoking any tools, even if the entire key directory is gone.
        XCTAssertThrowsError(try AndroidAPKExporter.build(
            configuration: .resolved(wrap, boosts: [], generatedBy: "test"),
            iconPNG: Data([1]), destination: directory.appendingPathComponent("out.apk"),
            sdkDirectory: directory.appendingPathComponent("missing-sdk"), javaHome: nil,
            signingDirectory: directory.appendingPathComponent("AndroidSigning"),
            passwords: .inMemory())) { error in
                guard case AndroidAPKExporter.ExportError.missingSigningKey = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("out.apk").path))
        XCTAssertEqual(try Data(contentsOf: record), Data(#"{"versionCode":3}"#.utf8))
    }

    func testInvalidRecordCannotResetVersionNumbers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrap = Wrap(name: "Test", homeURL: URL(string: "https://example.com")!)
        let records = directory.appendingPathComponent("AndroidExports")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let record = records.appendingPathComponent(AndroidExportPlan.packageIdentifier(for: wrap.id))
            .appendingPathExtension("json")
        for contents in ["{}", #"{"versionCode":0}"#, #"{"versionCode":-1}"#,
                         #"{"versionCode":2147483647}"#] {
            try Data(contents.utf8).write(to: record)
            XCTAssertThrowsError(try AndroidAPKExporter.build(
                configuration: .resolved(wrap, boosts: [], generatedBy: "test"),
                iconPNG: Data([1]), destination: directory.appendingPathComponent("out.apk"),
                sdkDirectory: directory.appendingPathComponent("missing-sdk"), javaHome: nil,
                signingDirectory: directory.appendingPathComponent("AndroidSigning"),
                passwords: .inMemory())) { error in
                    guard case AndroidAPKExporter.ExportError.invalidRecord = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                }
        }
    }

    func testMissingRecordCannotResetAnExistingIdentityVersion() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrap = Wrap(name: "Test", homeURL: URL(string: "https://example.com")!)
        let signing = directory.appendingPathComponent("AndroidSigning")
        let identity = signing.appendingPathComponent(AndroidExportPlan.packageIdentifier(for: wrap.id))
        try FileManager.default.createDirectory(at: identity, withIntermediateDirectories: true)
        let key = identity.appendingPathComponent("signing.p12")
        try Data("existing key".utf8).write(to: key)

        // Refuse before tool discovery; neither the version nor the key may reset.
        XCTAssertThrowsError(try AndroidAPKExporter.build(
            configuration: .resolved(wrap, boosts: [], generatedBy: "test"),
            iconPNG: Data([1]), destination: directory.appendingPathComponent("out.apk"),
            sdkDirectory: directory.appendingPathComponent("missing-sdk"),
            javaHome: directory.appendingPathComponent("missing-jdk"), signingDirectory: signing,
            passwords: .inMemory())) { error in
                guard case AndroidAPKExporter.ExportError.invalidRecord = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        XCTAssertEqual(try Data(contentsOf: key), Data("existing key".utf8))
    }

    func testReservedRecordWithoutAKeyCanRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrap = Wrap(name: "Test", homeURL: URL(string: "https://example.com")!)
        let records = directory.appendingPathComponent("AndroidExports")
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let record = records.appendingPathComponent(AndroidExportPlan.packageIdentifier(for: wrap.id))
            .appendingPathExtension("json")
        let reserved = Data(#"{"versionCode":3,"state":"reserved"}"#.utf8)
        try reserved.write(to: record)

        XCTAssertThrowsError(try AndroidAPKExporter.build(
            configuration: .resolved(wrap, boosts: [], generatedBy: "test"),
            iconPNG: Data([1]), destination: directory.appendingPathComponent("out.apk"),
            sdkDirectory: directory.appendingPathComponent("missing-sdk"),
            javaHome: directory.appendingPathComponent("missing-jdk"),
            signingDirectory: directory.appendingPathComponent("AndroidSigning"),
            passwords: .inMemory())) { error in
                // A first build that never reached key generation can reach tool discovery again.
                guard case AndroidToolchain.ToolchainError.missingFile = error else {
                    return XCTFail("Unexpected error: \(error)")
                }
            }
        XCTAssertEqual(try Data(contentsOf: record), reserved)
    }

    func testFailedFirstBuildReservesAVersionAndAllowsRetry() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let wrap = Wrap(name: "Test", homeURL: URL(string: "https://example.com")!)
        let sdk = directory.appendingPathComponent("sdk")
        let javaHome = directory.appendingPathComponent("jdk")
        for path in ["platforms/android-35/android.jar", "build-tools/35.0.0/lib/d8.jar",
                     "build-tools/35.0.0/lib/apksigner.jar", "build-tools/35.0.0/core-lambda-stubs.jar"] {
            try writeFixture("placeholder", to: sdk.appendingPathComponent(path))
        }
        for tool in ["aapt2", "zipalign"] {
            try writeExecutable("exit 1", to: sdk.appendingPathComponent("build-tools/35.0.0/\(tool)"))
        }
        for tool in ["java", "keytool", "jar"] {
            try writeExecutable("exit 1", to: javaHome.appendingPathComponent("bin/\(tool)"))
        }
        try writeExecutable("printf 'javac 17.0.1\\n'", to: javaHome.appendingPathComponent("bin/javac"))
        let signing = directory.appendingPathComponent("AndroidSigning")
        let recordURL = directory.appendingPathComponent("AndroidExports")
            .appendingPathComponent(AndroidExportPlan.packageIdentifier(for: wrap.id))
            .appendingPathExtension("json")

        for expectedVersion in [1, 2] {
            XCTAssertThrowsError(try AndroidAPKExporter.build(
                configuration: .resolved(wrap, boosts: [], generatedBy: "test"),
                iconPNG: Data([1]), destination: directory.appendingPathComponent("out.apk"),
                sdkDirectory: sdk, javaHome: javaHome, signingDirectory: signing,
                passwords: .inMemory())) { error in
                    guard case AndroidToolchain.ToolchainError.failed(let tool, _) = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertEqual(tool, "aapt2")
                }
            let record = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL))
                as? [String: Any])
            XCTAssertEqual(record["versionCode"] as? Int, expectedVersion)
            XCTAssertEqual(record["state"] as? String, "reserved")
            XCTAssertFalse(FileManager.default.fileExists(atPath: signing.path))
        }
    }

    private func writeFixture(_ content: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeExecutable(_ body: String, to url: URL) throws {
        try writeFixture("#!/bin/sh\n\(body)\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

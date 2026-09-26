import Foundation
import XCTest
@testable import Wrapybara

final class AndroidToolchainTests: XCTestCase {
    private var directory: URL!
    private var sdk: URL { directory.appendingPathComponent("Android SDK") }
    private var javaHome: URL { directory.appendingPathComponent("Java Home") }
    private var signingDirectory: URL { directory.appendingPathComponent("signing") }
    private let packageIdentifier = "com.wrapybara.test"

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        for path in ["platforms/android-35/android.jar", "build-tools/35.0.0/lib/d8.jar",
                     "build-tools/35.0.0/lib/apksigner.jar", "build-tools/35.0.0/core-lambda-stubs.jar"] {
            try write("placeholder", to: sdk.appendingPathComponent(path))
        }
        for tool in ["aapt2", "zipalign"] {
            try executable("exit 0", at: sdk.appendingPathComponent("build-tools/35.0.0/\(tool)"))
        }
        for tool in ["java", "jar", "keytool"] {
            try executable("exit 0", at: javaHome.appendingPathComponent("bin/\(tool)"))
        }
        try executable("printf 'javac 17.0.1\\n'", at: javaHome.appendingPathComponent("bin/javac"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testDiscoversCompleteToolchainInPathsWithSpaces() throws {
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        XCTAssertEqual(toolchain.androidJar, sdk.appendingPathComponent("platforms/android-35/android.jar"))
    }

    func testRejectsOldJava() throws {
        try executable("printf 'javac 11.0.2\\n'", at: javaHome.appendingPathComponent("bin/javac"))
        XCTAssertThrowsError(try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)) {
            guard case AndroidToolchain.ToolchainError.unsupportedJava = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testRejectsMissingPlatform() throws {
        let jar = sdk.appendingPathComponent("platforms/android-35/android.jar")
        try FileManager.default.removeItem(at: jar)
        XCTAssertThrowsError(try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)) {
            guard case AndroidToolchain.ToolchainError.missingFile(let path) = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
            XCTAssertEqual(path, jar.path)
        }
    }

    func testRejectsJavaRuntimeWithoutCompiler() throws {
        try FileManager.default.removeItem(at: javaHome.appendingPathComponent("bin/javac"))
        XCTAssertThrowsError(try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)) {
            guard case AndroidToolchain.ToolchainError.missingJavaTool = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
    }

    func testMissingPasswordNeverReplacesAnExistingKey() throws {
        let key = signingDirectory.appendingPathComponent(packageIdentifier + "/signing.p12")
        try write("existing key", to: key)
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)

        XCTAssertThrowsError(try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                                     packageIdentifier: packageIdentifier,
                                                                     toolchain: toolchain)) {
            guard case AndroidSigningIdentity.IdentityError.damagedIdentity = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertEqual(try String(contentsOf: key), "existing key")
        XCTAssertFalse(FileManager.default.fileExists(atPath: key.deletingLastPathComponent()
            .appendingPathComponent("password").path))
    }

    func testCorruptKeyIsPreservedAndReported() throws {
        let key = signingDirectory.appendingPathComponent(packageIdentifier + "/signing.p12")
        try write("corrupt key", to: key)
        try write("password", to: key.deletingLastPathComponent().appendingPathComponent("password"))
        try executable("exit 1", at: javaHome.appendingPathComponent("bin/keytool"))
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)

        XCTAssertThrowsError(try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                                     packageIdentifier: packageIdentifier,
                                                                     toolchain: toolchain)) {
            guard case AndroidSigningIdentity.IdentityError.damagedIdentity = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertEqual(try String(contentsOf: key), "corrupt key")
    }

    func testCreatesPrivateIdentityOnceAndReusesIt() throws {
        // The fake keytool exercises persistence; real signing is covered by the SDK smoke build.
        try executable("""
        case "$1" in
          -genkeypair)
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-keystore" ]; then
                shift
                printf 'test key' > "$1"
                exit 0
              fi
              shift
            done
            exit 1 ;;
          -list) exit 0 ;;
          *) exit 1 ;;
        esac
        """, at: javaHome.appendingPathComponent("bin/keytool"))
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        _ = try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                    packageIdentifier: packageIdentifier,
                                                    toolchain: toolchain)
        let identityDirectory = signingDirectory.appendingPathComponent(packageIdentifier)
        let key = identityDirectory.appendingPathComponent("signing.p12")
        let password = identityDirectory.appendingPathComponent("password")
        let originalPassword = try Data(contentsOf: password)
        XCTAssertEqual(try permissions(identityDirectory), 0o700)
        XCTAssertEqual(try permissions(key), 0o600)
        XCTAssertEqual(try permissions(password), 0o600)

        // Only validation may run on a rebuild. Generating a second key would fail this tool.
        try executable("[ \"$1\" = \"-list\" ]", at: javaHome.appendingPathComponent("bin/keytool"))
        _ = try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                    packageIdentifier: packageIdentifier,
                                                    toolchain: toolchain)
        XCTAssertEqual(try String(contentsOf: key), "test key")
        XCTAssertEqual(try Data(contentsOf: password), originalPassword)
    }

    func testFailedGenerationDoesNotPublishAnIncompleteIdentity() throws {
        try executable("exit 1", at: javaHome.appendingPathComponent("bin/keytool"))
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        XCTAssertThrowsError(try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                                     packageIdentifier: packageIdentifier,
                                                                     toolchain: toolchain))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: signingDirectory.path), [])
    }

    func testPackageIdentifierCannotEscapeSigningDirectory() throws {
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        XCTAssertThrowsError(try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                                     packageIdentifier: "../escape",
                                                                     toolchain: toolchain))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("escape").path))
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func executable(_ body: String, at url: URL) throws {
        try write("#!/bin/sh\n\(body)\n", to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue
    }
}

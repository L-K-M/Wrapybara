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
        let passwords = AndroidSigningPasswordStore.inMemory()

        XCTAssertThrowsError(try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                                     packageIdentifier: packageIdentifier,
                                                                     toolchain: toolchain,
                                                                     passwords: passwords)) {
            guard case AndroidSigningIdentity.IdentityError.missingPassword = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertEqual(try String(contentsOf: key), "existing key")
        XCTAssertNil(try passwords.read(packageIdentifier))
    }

    func testCorruptKeyIsPreservedAndReported() throws {
        let key = signingDirectory.appendingPathComponent(packageIdentifier + "/signing.p12")
        try write("corrupt key", to: key)
        try executable("exit 1", at: javaHome.appendingPathComponent("bin/keytool"))
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        let passwords = AndroidSigningPasswordStore.inMemory()
        try passwords.add("password", packageIdentifier)

        XCTAssertThrowsError(try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                                     packageIdentifier: packageIdentifier,
                                                                     toolchain: toolchain,
                                                                     passwords: passwords)) {
            guard case AndroidSigningIdentity.IdentityError.damagedIdentity = $0 else {
                return XCTFail("Unexpected error: \($0)")
            }
        }
        XCTAssertEqual(try String(contentsOf: key), "corrupt key")
    }

    func testCreatesPrivateIdentityOnceAndReusesIt() throws {
        // The fake keytool exercises persistence and insists on getting the password from
        // the environment; real signing is covered by the SDK smoke build.
        try executable("""
        [ -n "$WRAPYBARA_ANDROID_KEYSTORE_PASSWORD" ] || exit 2
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
        let passwords = AndroidSigningPasswordStore.inMemory()
        _ = try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                    packageIdentifier: packageIdentifier,
                                                    toolchain: toolchain, passwords: passwords)
        let identityDirectory = signingDirectory.appendingPathComponent(packageIdentifier)
        let key = identityDirectory.appendingPathComponent("signing.p12")
        let password = try XCTUnwrap(passwords.read(packageIdentifier))
        XCTAssertFalse(password.isEmpty)
        // The key is all the folder holds; its password never touches the disk.
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: identityDirectory.path),
                       ["signing.p12"])
        XCTAssertEqual(try permissions(identityDirectory), 0o700)
        XCTAssertEqual(try permissions(key), 0o600)

        // Only validation may run on a rebuild. Generating a second key would fail this tool.
        try executable("""
        [ -n "$WRAPYBARA_ANDROID_KEYSTORE_PASSWORD" ] && [ "$1" = "-list" ]
        """, at: javaHome.appendingPathComponent("bin/keytool"))
        let reloaded = try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                               packageIdentifier: packageIdentifier,
                                                               toolchain: toolchain, passwords: passwords)
        XCTAssertEqual(try String(contentsOf: key), "test key")
        XCTAssertEqual(Array(reloaded.environment.values), [password])
        XCTAssertFalse(reloaded.signingArguments.contains(password))
    }

    func testANewKeyReusesThePackagesStoredPassword() throws {
        // A stored password is never replaced: a key restored from backup still needs it.
        try executable("""
        [ "$WRAPYBARA_ANDROID_KEYSTORE_PASSWORD" = "kept" ] || exit 2
        case "$1" in
          -genkeypair)
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "-keystore" ]; then shift; printf 'new key' > "$1"; exit 0; fi
              shift
            done
            exit 1 ;;
          -list) exit 0 ;;
          *) exit 1 ;;
        esac
        """, at: javaHome.appendingPathComponent("bin/keytool"))
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        let passwords = AndroidSigningPasswordStore.inMemory()
        try passwords.add("kept", packageIdentifier)

        _ = try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                    packageIdentifier: packageIdentifier,
                                                    toolchain: toolchain, passwords: passwords)
        XCTAssertEqual(try passwords.read(packageIdentifier), "kept")
    }

    func testMovesALegacyPasswordFileIntoTheStore() throws {
        let identityDirectory = signingDirectory.appendingPathComponent(packageIdentifier)
        let key = identityDirectory.appendingPathComponent("signing.p12")
        let legacyPassword = identityDirectory.appendingPathComponent("password")
        try write("existing key", to: key)
        try write("legacy password", to: legacyPassword)
        try executable("""
        [ "$WRAPYBARA_ANDROID_KEYSTORE_PASSWORD" = "legacy password" ] && [ "$1" = "-list" ]
        """, at: javaHome.appendingPathComponent("bin/keytool"))
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        let passwords = AndroidSigningPasswordStore.inMemory()

        _ = try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                    packageIdentifier: packageIdentifier,
                                                    toolchain: toolchain, passwords: passwords)
        XCTAssertEqual(try passwords.read(packageIdentifier), "legacy password")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyPassword.path))
        XCTAssertEqual(try String(contentsOf: key), "existing key")
    }

    func testALegacyPasswordFileWinsOverADifferentStoredPassword() throws {
        // A failed first export can leave a stored password behind; a pre-Keychain
        // folder restored afterwards must still open with its own password file.
        let identityDirectory = signingDirectory.appendingPathComponent(packageIdentifier)
        let key = identityDirectory.appendingPathComponent("signing.p12")
        let legacyPassword = identityDirectory.appendingPathComponent("password")
        try write("restored key", to: key)
        try write("legacy password", to: legacyPassword)
        try executable("""
        [ "$WRAPYBARA_ANDROID_KEYSTORE_PASSWORD" = "legacy password" ] && [ "$1" = "-list" ]
        """, at: javaHome.appendingPathComponent("bin/keytool"))
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        let passwords = AndroidSigningPasswordStore.inMemory()
        try passwords.add("left by a failed export", packageIdentifier)

        _ = try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                    packageIdentifier: packageIdentifier,
                                                    toolchain: toolchain, passwords: passwords)
        XCTAssertEqual(try passwords.read(packageIdentifier), "left by a failed export")
        // Never replaced in the store, so the file stays: it's the key's only copy.
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyPassword.path))
        XCTAssertEqual(try String(contentsOf: key), "restored key")
    }

    func testFailedGenerationDoesNotPublishAnIncompleteIdentity() throws {
        try executable("exit 1", at: javaHome.appendingPathComponent("bin/keytool"))
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        XCTAssertThrowsError(try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                                     packageIdentifier: packageIdentifier,
                                                                     toolchain: toolchain,
                                                                     passwords: .inMemory()))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: signingDirectory.path), [])
    }

    func testPackageIdentifierCannotEscapeSigningDirectory() throws {
        let toolchain = try AndroidToolchain.discover(sdkDirectory: sdk, javaHome: javaHome)
        let passwords = AndroidSigningPasswordStore.inMemory()
        for identifier in ["../escape", "../../escape", "com.wrapybara.test/../../escape"] {
            XCTAssertThrowsError(try AndroidSigningIdentity.loadOrCreate(in: signingDirectory,
                                                                         packageIdentifier: identifier,
                                                                         toolchain: toolchain,
                                                                         passwords: passwords))
            XCTAssertNil(try passwords.read(identifier))
            XCTAssertNil(try passwords.read("escape"))
        }
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

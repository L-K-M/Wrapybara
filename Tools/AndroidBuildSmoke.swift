import Foundation

/// Exercises the production packager with real SDK tools on Linux or macOS.
@main
enum AndroidBuildSmoke {
    private enum Failure: Error { case check(String) }

    private static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure.check(message) }
    }

    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 4 else {
            throw Failure.check("Expected repository, Android SDK, and JDK home paths")
        }
        let repository = URL(fileURLWithPath: arguments[1])
        let tools = try AndroidToolchain.discover(sdkDirectory: URL(fileURLWithPath: arguments[2]),
                                                 javaHome: URL(fileURLWithPath: arguments[3]))
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Wrapybara Android smoke \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let signing = directory.appendingPathComponent("signing")
        let package = "com.wrapybara.smoke"
        let identityDirectory = signing.appendingPathComponent(package)
        let key = identityDirectory.appendingPathComponent("signing.p12")
        let legacyPassword = identityDirectory.appendingPathComponent("password")
        let passwords = AndroidSigningPasswordStore.inMemory()
        var certificate: String?
        var originalKey: Data?

        for version in 1...2 {
            let project = directory.appendingPathComponent("version \(version)")
            try writeFixture(to: project, repository: repository, package: package, version: version)
            let apk = try AndroidAPKBuilder.build(projectDirectory: project, toolchain: tools,
                                                  signingDirectory: signing, packageIdentifier: package,
                                                  passwords: passwords)
            try require(!FileManager.default.fileExists(atPath: legacyPassword.path),
                        "Signing password was written to disk")
            let verification = try tools.run(.java, arguments: [
                "-jar", tools.apkSignerJar.path, "verify", "--print-certs", apk.path
            ]).standardOutput
            let digest = verification.split(separator: "\n").first { $0.contains("certificate SHA-256 digest:") }
            guard let digest else { throw Failure.check("APK has no verified signing certificate") }
            if let certificate { try require(String(digest) == certificate, "Update changed signing key") }
            certificate = String(digest)
            let keyData = try Data(contentsOf: key)
            if let originalKey { try require(originalKey == keyData, "Update rewrote keystore") }
            originalKey = keyData

            let badging = try tools.run(.aapt2, arguments: ["dump", "badging", apk.path]).standardOutput
            try require(badging.contains("versionCode='\(version)'"), "Wrong update version")
            try require(badging.contains(package), "Wrong package identity")
            let listing = try tools.run(.jar, arguments: ["--list", "--file", apk.path]).standardOutput
            for entry in ["classes.dex", "assets/wrap.json", "assets/boosts.json", "resources.arsc"] {
                try require(listing.contains(entry), "Missing \(entry)")
            }
        }

        // A key whose password is gone must fail instead of being replaced behind installed apps.
        do {
            _ = try AndroidSigningIdentity.loadOrCreate(in: signing, packageIdentifier: package,
                                                        toolchain: tools, passwords: .inMemory())
            throw Failure.check("Missing password silently regenerated an identity")
        } catch AndroidSigningIdentity.IdentityError.missingPassword { }

        // So must a password that no longer opens the key.
        let wrongPasswords = AndroidSigningPasswordStore.inMemory()
        try wrongPasswords.add("not the password", package)
        do {
            _ = try AndroidSigningIdentity.loadOrCreate(in: signing, packageIdentifier: package,
                                                        toolchain: tools, passwords: wrongPasswords)
            throw Failure.check("A wrong password was accepted")
        } catch AndroidSigningIdentity.IdentityError.damagedIdentity { }

        // A pre-Keychain identity keeps working: its password file moves into the store.
        guard let password = try passwords.read(package) else {
            throw Failure.check("The signing password was not stored")
        }
        try Data(password.utf8).write(to: legacyPassword)
        let migrated = AndroidSigningPasswordStore.inMemory()
        _ = try AndroidSigningIdentity.loadOrCreate(in: signing, packageIdentifier: package,
                                                    toolchain: tools, passwords: migrated)
        let migratedPassword = try migrated.read(package)
        try require(migratedPassword == password, "The legacy password was not migrated")
        try require(!FileManager.default.fileExists(atPath: legacyPassword.path),
                    "The legacy password file was kept")

        let remainingKey = try Data(contentsOf: key)
        try require(remainingKey == originalKey, "Identity checks changed the existing keystore")
        print("APK build, contents, signature, update identity, password storage "
              + "and damaged-key checks passed")
    }

    private static func writeFixture(to directory: URL, repository: URL,
                                     package: String, version: Int) throws {
        for path in ["res/drawable", "res/values", "assets", "src/com/wrapybara/runtime"] {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(path),
                                                    withIntermediateDirectories: true)
        }
        let manifest = """
        <manifest xmlns:android="http://schemas.android.com/apk/res/android"
            package="\(package)" android:versionCode="\(version)" android:versionName="\(version)">
          <uses-sdk android:minSdkVersion="\(AndroidToolchain.minimumSDK)"
              android:targetSdkVersion="\(AndroidToolchain.targetSDK)" />
          <uses-permission android:name="android.permission.INTERNET" />
          <application android:label="@string/app_name" android:icon="@drawable/icon"
              android:theme="@android:style/Theme.Material.Light.NoActionBar" android:allowBackup="false">
            <activity android:name="com.wrapybara.runtime.AndroidSiteActivity" android:exported="true">
              <intent-filter><action android:name="android.intent.action.MAIN" />
                <category android:name="android.intent.category.LAUNCHER" /></intent-filter>
            </activity>
          </application>
        </manifest>
        """
        try manifest.write(to: directory.appendingPathComponent("AndroidManifest.xml"),
                           atomically: true, encoding: .utf8)
        try #"<resources><string name="app_name" formatted="false">"@O\'Reilly &amp; &lt;\"Site\"&gt; \\ %s"</string></resources>"#
            .write(to: directory.appendingPathComponent("res/values/strings.xml"), atomically: true, encoding: .utf8)
        try FileManager.default.copyItem(at: repository.appendingPathComponent("docs/icon.png"),
                                          to: directory.appendingPathComponent("res/drawable/icon.png"))
        try #"{"name":"Example","homeURL":"https://example.com","allowedDomains":["example.com"]}"#
            .write(to: directory.appendingPathComponent("assets/wrap.json"), atomically: true, encoding: .utf8)
        try "[]".write(to: directory.appendingPathComponent("assets/boosts.json"),
                       atomically: true, encoding: .utf8)
        for name in ["AndroidSiteActivity", "AndroidNavigationPolicy"] {
            try FileManager.default.copyItem(
                at: repository.appendingPathComponent("Wrapybara/Export/\(name).java.txt"),
                to: directory.appendingPathComponent("src/com/wrapybara/runtime/\(name).java"))
        }
    }
}

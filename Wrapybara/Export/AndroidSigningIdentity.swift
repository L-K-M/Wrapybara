import Foundation

/// Keeps each package's signing key stable so Android can install later exports as updates.
///
/// The key lives in the signing folder and its password in an
/// `AndroidSigningPasswordStore` (the login Keychain in the app), so neither half
/// signs an update on its own. The tools read the password from an environment
/// variable, never from a file or an argument.
struct AndroidSigningIdentity {
    private static let alias = "wrapybara"
    private static let keyStoreName = "signing.p12"
    /// Where the password lived before the Keychain; moved there on first load.
    private static let legacyPasswordName = "password"
    private static let passwordVariable = "WRAPYBARA_ANDROID_KEYSTORE_PASSWORD"
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600
    private static let passwordByteCount = 32
    private static let keySize = 2048
    private static let validityDays = 10_000

    enum IdentityError: LocalizedError {
        case invalidPackageIdentifier
        case damagedIdentity(String)
        case missingPassword(String)

        var errorDescription: String? {
            switch self {
            case .invalidPackageIdentifier:
                return "The Android package identifier is invalid."
            case .damagedIdentity(let path):
                return "The Android signing key at \(path) is incomplete or unreadable. "
                    + "Restore its folder from backup; a new key cannot update your installed app."
            case .missingPassword(let packageIdentifier):
                return "The password for the Android signing key \(packageIdentifier) is missing "
                    + "from your Keychain. Restore your Keychain from backup; a new key cannot "
                    + "update your installed app."
            }
        }
    }

    private let directory: URL
    private let password: String
    private var keyStore: URL { directory.appendingPathComponent(Self.keyStoreName) }

    /// For `apksigner sign`; run it with `environment`, which carries the password.
    var signingArguments: [String] {
        ["--ks", keyStore.path, "--ks-type", "PKCS12", "--ks-key-alias", Self.alias,
         "--ks-pass", "env:\(Self.passwordVariable)"]
    }

    var environment: [String: String] { [Self.passwordVariable: password] }

    static func loadOrCreate(in signingDirectory: URL, packageIdentifier: String,
                             toolchain: AndroidToolchain,
                             passwords: AndroidSigningPasswordStore) throws -> AndroidSigningIdentity {
        guard packageIdentifier.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$",
                                      options: .regularExpression) != nil else {
            throw IdentityError.invalidPackageIdentifier
        }

        let manager = FileManager.default
        let directory = signingDirectory.appendingPathComponent(packageIdentifier, isDirectory: true)
        if manager.fileExists(atPath: directory.path) {
            let identity = AndroidSigningIdentity(
                directory: directory,
                password: try storedPassword(for: packageIdentifier, in: directory, passwords: passwords))
            try identity.validate(using: toolchain)
            try identity.removeLegacyPassword(ifStoredIn: passwords, for: packageIdentifier)
            return identity
        }

        try manager.createDirectory(at: signingDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: directoryPermissions])
        try manager.setAttributes([.posixPermissions: directoryPermissions],
                                  ofItemAtPath: signingDirectory.path)

        // One password per package, stored before its key is made and never replaced,
        // so a key restored later from backup still opens with it.
        let password: String
        if let existing = try passwords.read(packageIdentifier) {
            password = existing
        } else {
            password = Data((0..<passwordByteCount).map { _ in UInt8.random(in: .min ... .max) })
                .base64EncodedString()
            try passwords.add(password, packageIdentifier)
        }

        // Publish the complete identity together; interrupted key generation leaves no partial key.
        let stagingDirectory = signingDirectory.appendingPathComponent(".\(UUID().uuidString)")
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: directoryPermissions])
        defer { try? manager.removeItem(at: stagingDirectory) }
        let staged = AndroidSigningIdentity(directory: stagingDirectory, password: password)

        try toolchain.run(.keytool, arguments: [
            "-genkeypair", "-noprompt", "-keystore", staged.keyStore.path,
            "-storetype", "PKCS12", "-storepass:env", passwordVariable,
            "-keypass:env", passwordVariable, "-alias", alias,
            "-keyalg", "RSA", "-keysize", String(keySize), "-sigalg", "SHA256withRSA",
            "-validity", String(validityDays), "-dname", "CN=Wrapybara Android App"
        ], environment: staged.environment)
        try staged.validate(using: toolchain)
        try manager.moveItem(at: stagingDirectory, to: directory)
        return AndroidSigningIdentity(directory: directory, password: password)
    }

    /// The password for the key in `directory`. A pre-Keychain password file beside
    /// the key is that key's own password, so it wins over the store: it moves into
    /// an empty store, and never replaces a password already stored.
    private static func storedPassword(for packageIdentifier: String, in directory: URL,
                                       passwords: AndroidSigningPasswordStore) throws -> String {
        let stored = try passwords.read(packageIdentifier)
        let legacyFile = directory.appendingPathComponent(legacyPasswordName)
        if let data = try? Data(contentsOf: legacyFile),
           let legacy = String(data: data, encoding: .utf8), !legacy.isEmpty {
            if stored == nil { try passwords.add(legacy, packageIdentifier) }
            return legacy
        }

        guard let stored else { throw IdentityError.missingPassword(packageIdentifier) }
        return stored
    }

    /// Once the key has opened, its plaintext password file goes, but only when the
    /// store holds the same password; otherwise the file is the key's only copy.
    private func removeLegacyPassword(ifStoredIn passwords: AndroidSigningPasswordStore,
                                      for packageIdentifier: String) throws {
        let legacyFile = directory.appendingPathComponent(Self.legacyPasswordName)
        guard FileManager.default.fileExists(atPath: legacyFile.path),
              try passwords.read(packageIdentifier) == password else { return }
        try FileManager.default.removeItem(at: legacyFile)
    }

    private func validate(using toolchain: AndroidToolchain) throws {
        let manager = FileManager.default
        do {
            let attributes = try manager.attributesOfItem(atPath: keyStore.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
                throw IdentityError.damagedIdentity(directory.path)
            }
            try manager.setAttributes([.posixPermissions: Self.filePermissions],
                                      ofItemAtPath: keyStore.path)
            try manager.setAttributes([.posixPermissions: Self.directoryPermissions],
                                      ofItemAtPath: directory.path)
            try toolchain.run(.keytool, arguments: [
                "-list", "-keystore", keyStore.path, "-storetype", "PKCS12",
                "-storepass:env", Self.passwordVariable, "-alias", Self.alias
            ], environment: environment)
        } catch let error as ProcessRunner.RunError {
            // keytool couldn't start or hung: a toolchain problem, not a damaged key.
            throw error
        } catch {
            throw IdentityError.damagedIdentity(directory.path)
        }
    }
}

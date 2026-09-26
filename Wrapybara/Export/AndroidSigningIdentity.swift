import Foundation

/// Keeps each package's signing key stable so Android can install later exports as updates.
struct AndroidSigningIdentity {
    private static let alias = "wrapybara"
    private static let keyStoreName = "signing.p12"
    private static let passwordName = "password"
    private static let directoryPermissions = 0o700
    private static let filePermissions = 0o600
    private static let passwordByteCount = 32
    private static let keySize = 2048
    private static let validityDays = 10_000

    enum IdentityError: LocalizedError {
        case invalidPackageIdentifier
        case damagedIdentity(String)

        var errorDescription: String? {
            switch self {
            case .invalidPackageIdentifier:
                return "The Android package identifier is invalid."
            case .damagedIdentity(let path):
                return "The Android signing key at \(path) is incomplete or unreadable. "
                    + "Restore its folder from backup; a new key cannot update your installed app."
            }
        }
    }

    private let directory: URL
    private var keyStore: URL { directory.appendingPathComponent(Self.keyStoreName) }
    private var passwordFile: URL { directory.appendingPathComponent(Self.passwordName) }

    var signingArguments: [String] {
        // PKCS12 uses the store password for its key; reusing the file twice reads past EOF.
        ["--ks", keyStore.path, "--ks-type", "PKCS12", "--ks-key-alias", Self.alias,
         "--ks-pass", "file:\(passwordFile.path)"]
    }

    static func loadOrCreate(in signingDirectory: URL, packageIdentifier: String,
                             toolchain: AndroidToolchain) throws -> AndroidSigningIdentity {
        guard packageIdentifier.range(of: "^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)+$",
                                      options: .regularExpression) != nil else {
            throw IdentityError.invalidPackageIdentifier
        }

        let manager = FileManager.default
        let directory = signingDirectory.appendingPathComponent(packageIdentifier, isDirectory: true)
        let identity = AndroidSigningIdentity(directory: directory)
        if manager.fileExists(atPath: directory.path) {
            try identity.validate(using: toolchain)
            return identity
        }

        try manager.createDirectory(at: signingDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: directoryPermissions])
        try manager.setAttributes([.posixPermissions: directoryPermissions],
                                  ofItemAtPath: signingDirectory.path)

        // Publish the complete identity together; interrupted key generation leaves no partial key.
        let stagingDirectory = signingDirectory.appendingPathComponent(".\(UUID().uuidString)")
        try manager.createDirectory(at: stagingDirectory, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: directoryPermissions])
        defer { try? manager.removeItem(at: stagingDirectory) }
        let staged = AndroidSigningIdentity(directory: stagingDirectory)
        let password = Data((0..<passwordByteCount).map { _ in UInt8.random(in: .min ... .max) })
            .base64EncodedString()
        try Data(password.utf8).write(to: staged.passwordFile, options: .atomic)
        try manager.setAttributes([.posixPermissions: filePermissions],
                                  ofItemAtPath: staged.passwordFile.path)

        try toolchain.run(.keytool, arguments: [
            "-genkeypair", "-noprompt", "-keystore", staged.keyStore.path,
            "-storetype", "PKCS12", "-storepass:file", staged.passwordFile.path,
            "-keypass:file", staged.passwordFile.path, "-alias", alias,
            "-keyalg", "RSA", "-keysize", String(keySize), "-sigalg", "SHA256withRSA",
            "-validity", String(validityDays), "-dname", "CN=Wrapybara Android App"
        ])
        try staged.validate(using: toolchain)
        try manager.moveItem(at: stagingDirectory, to: directory)
        return identity
    }

    private func validate(using toolchain: AndroidToolchain) throws {
        let manager = FileManager.default
        do {
            for file in [keyStore, passwordFile] {
                let attributes = try manager.attributesOfItem(atPath: file.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular,
                      let size = attributes[.size] as? NSNumber, size.intValue > 0 else {
                    throw IdentityError.damagedIdentity(directory.path)
                }
                try manager.setAttributes([.posixPermissions: Self.filePermissions],
                                          ofItemAtPath: file.path)
            }
            try manager.setAttributes([.posixPermissions: Self.directoryPermissions],
                                      ofItemAtPath: directory.path)
            try toolchain.run(.keytool, arguments: [
                "-list", "-keystore", keyStore.path, "-storetype", "PKCS12",
                "-storepass:file", passwordFile.path, "-alias", Self.alias
            ])
        } catch {
            throw IdentityError.damagedIdentity(directory.path)
        }
    }
}

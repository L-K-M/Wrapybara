import Foundation
#if canImport(Security)
import Security
#endif

/// Where each Android package's signing password lives, apart from its key.
///
/// In the app that's the login Keychain (`keychain`), so the signing folder on its
/// own, in a synced or unencrypted backup, can't sign an update. Tests and the Linux
/// build smoke use `inMemory()`, so neither touches, or prompts for, a real Keychain.
struct AndroidSigningPasswordStore {
    enum StoreError: LocalizedError {
        case duplicate(String)
        case unreadable(String)
        case keychain(Int32)

        var errorDescription: String? {
            switch self {
            case .duplicate(let packageIdentifier):
                return "A signing password for \(packageIdentifier) is already stored."
            case .unreadable(let packageIdentifier):
                return "The stored signing password for \(packageIdentifier) is unreadable."
            case .keychain(let status):
                return "Your Keychain refused the Android signing password (error \(status))."
            }
        }
    }

    /// The package's password, or nil when it has none.
    var read: (_ packageIdentifier: String) throws -> String?

    /// Adds a password and never replaces one: a key restored from backup still
    /// opens with the password it was made with.
    var add: (_ password: String, _ packageIdentifier: String) throws -> Void

    /// A store that lives only as long as the value, for tests and the build smoke.
    static func inMemory() -> AndroidSigningPasswordStore {
        final class Passwords { var byPackage: [String: String] = [:] }
        let passwords = Passwords()
        return AndroidSigningPasswordStore(
            read: { passwords.byPackage[$0] },
            add: { password, packageIdentifier in
                guard passwords.byPackage[packageIdentifier] == nil else {
                    throw StoreError.duplicate(packageIdentifier)
                }
                passwords.byPackage[packageIdentifier] = password
            })
    }
}

#if canImport(Security)
extension AndroidSigningPasswordStore {
    /// One service for every package. A literal, never anything from `Bundle.main`,
    /// so every copy of Wrapybara, however it's named or signed, finds the same items.
    private static let keychainService = "com.wrapybara.android-signing"

    /// The login Keychain. macOS may ask once before a re-signed Wrapybara reads it.
    static let keychain = AndroidSigningPasswordStore(
        read: { packageIdentifier in
            var query = AndroidSigningPasswordStore.keychainQuery(for: packageIdentifier)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess else { throw StoreError.keychain(status) }
            guard let data = item as? Data, let password = String(data: data, encoding: .utf8) else {
                throw StoreError.unreadable(packageIdentifier)
            }
            return password
        },
        add: { password, packageIdentifier in
            var attributes = AndroidSigningPasswordStore.keychainQuery(for: packageIdentifier)
            attributes[kSecValueData as String] = Data(password.utf8)
            attributes[kSecAttrLabel as String] = "Wrapybara Android signing key (\(packageIdentifier))"
            let status = SecItemAdd(attributes as CFDictionary, nil)
            if status == errSecDuplicateItem { throw StoreError.duplicate(packageIdentifier) }
            guard status == errSecSuccess else { throw StoreError.keychain(status) }
        })

    private static func keychainQuery(for packageIdentifier: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: keychainService,
         kSecAttrAccount as String: packageIdentifier]
    }
}
#endif

import Foundation

/// The little bit of extended-attribute work generating an app needs.
///
/// Exists for one specific failure: if the user opened Wrapybara by
/// right-click → Open rather than clearing quarantine, Wrapybara's own files still
/// carry `com.apple.quarantine`. `FileManager` copies extended attributes, so the
/// runtime binary copied into a new wrap would inherit it — and the brand-new app
/// the user just built would be Gatekeeper-blocked for no reason they could see.
enum ExtendedAttributes {

    static let quarantine = "com.apple.quarantine"

    /// Removes `name` from the item at `url`, following no symlinks. A missing
    /// attribute is success — there is nothing to report and nothing to fix.
    static func remove(_ name: String, from url: URL) {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            // `removexattr` returns ENOATTR when the attribute isn't there, which is
            // the common case and not an error worth surfacing.
            _ = removexattr(path, name, XATTR_NOFOLLOW)
        }
    }

    /// Removes `name` from `url` and everything beneath it.
    static func removeRecursively(_ name: String, from url: URL) {
        remove(name, from: url)
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: nil,
            options: [])
        else { return }
        for case let child as URL in enumerator {
            remove(name, from: child)
        }
    }
}

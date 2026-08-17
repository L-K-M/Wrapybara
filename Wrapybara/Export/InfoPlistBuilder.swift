import Foundation

/// Builds the `Info.plist` for a generated app.
///
/// Pure — it returns a dictionary and never touches the file system — so the whole
/// plist can be asserted on in tests. `AppBundleWriter` serialises it.
///
/// The generated app gets a hand-written plist rather than a copy of Wrapybara's:
/// bundle identifier, name, icon and the usage strings all have to name *the site*,
/// and half the point of the exercise is that the result looks like an app someone
/// wrote on purpose.
enum InfoPlistBuilder {

    /// Custom keys the runtime reads out of its own bundle.
    enum Key {
        /// The wrap's UUID — how a generated app finds its entry in the shared
        /// runtime store.
        static let wrapIdentifier = "WBWrapIdentifier"
        /// Name of the baked-in seed config inside `Contents/Resources`.
        static let configurationFile = "WBWrapConfigurationFile"
        /// Last-resort home URL, used if both config copies are unreadable.
        static let homeURL = "WBHomeURL"
        /// The Wrapybara version that generated the bundle, for the About panel.
        static let generatedBy = "WBGeneratedBy"
    }

    /// The seed config's file name inside `Contents/Resources`.
    static let configurationFileName = "wrap.json"
    /// The icon file name (without extension) inside `Contents/Resources`.
    static let iconFileName = "AppIcon"

    /// - Parameters:
    ///   - wrap: the wrap being exported.
    ///   - executableName: the file name of the runtime copy in `Contents/MacOS`.
    ///     Must match, or Launch Services refuses to open the bundle.
    ///   - version: `CFBundleShortVersionString` for the generated app — the site's
    ///     app version, which is Wrapybara's own version, since that's what the
    ///     runtime inside it came from.
    ///   - buildNumber: `CFBundleVersion`.
    ///   - generatedBy: a human string for the About panel.
    static func plist(for wrap: Wrap,
                      executableName: String,
                      version: String,
                      buildNumber: String,
                      generatedBy: String) -> [String: Any] {
        var plist: [String: Any] = [
            "CFBundleDevelopmentRegion": "en",
            "CFBundleDisplayName": wrap.name,
            "CFBundleExecutable": executableName,
            "CFBundleIconFile": iconFileName,
            "CFBundleIdentifier": wrap.bundleIdentifier,
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": truncatedBundleName(wrap.name),
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": version,
            "CFBundleVersion": buildNumber,
            "LSApplicationCategoryType": "public.app-category.productivity",
            "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": true,
            "NSPrincipalClass": "NSApplication",
            "NSSupportsAutomaticGraphicsSwitching": true,
            "NSHumanReadableCopyright": copyright(for: wrap),

            // A web view can ask for the camera and the microphone, and macOS kills
            // any process that triggers a TCC prompt without a usage string. Naming
            // the site (rather than "this app") is what the user will read in the
            // dialog.
            "NSCameraUsageDescription":
                "\(wrap.name) needs the camera when \(wrap.homeHost) asks for it.",
            "NSMicrophoneUsageDescription":
                "\(wrap.name) needs the microphone when \(wrap.homeHost) asks for it.",

            Key.wrapIdentifier: wrap.id.uuidString,
            Key.configurationFile: configurationFileName,
            Key.homeURL: wrap.homeURL.absoluteString,
            Key.generatedBy: generatedBy,
        ]

        // An `http://` home URL can't load at all under App Transport Security
        // without an exception, and refusing to wrap an intranet tool on a plain
        // HTTP host would be an odd hill to die on. The exception is scoped to that
        // one host — nothing else in the app gets to be insecure.
        if let exception = appTransportSecurity(for: wrap.homeURL) {
            plist["NSAppTransportSecurity"] = exception
        }

        return plist
    }

    /// `CFBundleName` is documented as 15 characters or fewer — it's what the menu
    /// bar falls back to. Longer names live in `CFBundleDisplayName`, which has no
    /// limit and is what macOS actually shows for an app on disk.
    static func truncatedBundleName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 15 else { return trimmed }
        return String(trimmed.prefix(15))
    }

    static func copyright(for wrap: Wrap) -> String {
        let host = wrap.homeHost.isEmpty ? "the site it wraps" : wrap.homeHost
        return "Web content © its owners. \(wrap.name) is a Wrapybara wrapper around \(host)."
    }

    /// An ATS dictionary allowing insecure loads for `url`'s host, or `nil` when the
    /// URL is already HTTPS and no exception is needed.
    static func appTransportSecurity(for url: URL) -> [String: Any]? {
        guard (url.scheme ?? "").lowercased() == "http", let host = url.host, !host.isEmpty else {
            return nil
        }
        return [
            "NSExceptionDomains": [
                host: [
                    "NSExceptionAllowsInsecureHTTPLoads": true,
                    "NSIncludesSubdomains": true,
                ],
            ],
        ]
    }
}

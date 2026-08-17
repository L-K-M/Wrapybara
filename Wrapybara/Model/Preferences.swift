import AppKit

/// Wrapybara's own settings — the builder's, not a wrap's. Anything that belongs to
/// one wrap lives in `WrapBehavior` and travels with it.
final class Preferences: ObservableObject {

    static let shared = Preferences()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.installDirectoryPath = defaults.string(forKey: Key.installDirectory)
            ?? Self.defaultInstallDirectory.path
        self.signingIdentity = defaults.string(forKey: Key.signingIdentity) ?? CodeSigner.adHocIdentity
        self.iconStyle = IconComposer.Style(rawValue: defaults.string(forKey: Key.iconStyle) ?? "")
            ?? .plate
        self.revealAfterBuild = defaults.object(forKey: Key.revealAfterBuild) as? Bool ?? false
        self.launchAfterBuild = defaults.object(forKey: Key.launchAfterBuild) as? Bool ?? true
        self.warnsBeforeTrustingImportedScripts =
            defaults.object(forKey: Key.warnsBeforeTrustingImportedScripts) as? Bool ?? true
    }

    private enum Key {
        static let installDirectory = "Preferences.installDirectory"
        static let signingIdentity = "Preferences.signingIdentity"
        static let iconStyle = "Preferences.iconStyle"
        static let revealAfterBuild = "Preferences.revealAfterBuild"
        static let launchAfterBuild = "Preferences.launchAfterBuild"
        static let warnsBeforeTrustingImportedScripts = "Preferences.warnsBeforeTrustingImportedScripts"
    }

    // MARK: Build destination

    /// Where new wraps are written.
    @Published var installDirectoryPath: String {
        didSet { defaults.set(installDirectoryPath, forKey: Key.installDirectory) }
    }

    var installDirectory: URL { URL(fileURLWithPath: installDirectoryPath, isDirectory: true) }

    /// `/Applications` when the account can write there (admins can), otherwise
    /// `~/Applications`.
    ///
    /// Preferring `/Applications` is deliberate: a wrap is meant to be a real app,
    /// and real apps live where Spotlight, Launchpad and every "choose an
    /// application" panel look first.
    static var defaultInstallDirectory: URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        return userApplicationsDirectory
    }

    static var userApplicationsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
    }

    // MARK: Signing

    /// `-` for ad-hoc, or a Developer ID common name from
    /// `CodeSigner.availableSigningIdentities()`.
    ///
    /// Ad-hoc is the default because it needs nothing and is enough to launch. A user
    /// who has a Developer ID gets apps that don't trip Gatekeeper at all, which is
    /// worth offering even though most people won't have one.
    @Published var signingIdentity: String {
        didSet { defaults.set(signingIdentity, forKey: Key.signingIdentity) }
    }

    var isSigningAdHoc: Bool { signingIdentity == CodeSigner.adHocIdentity }

    // MARK: Icons

    @Published var iconStyle: IconComposer.Style {
        didSet { defaults.set(iconStyle.rawValue, forKey: Key.iconStyle) }
    }

    // MARK: After building

    @Published var revealAfterBuild: Bool {
        didSet { defaults.set(revealAfterBuild, forKey: Key.revealAfterBuild) }
    }

    @Published var launchAfterBuild: Bool {
        didSet { defaults.set(launchAfterBuild, forKey: Key.launchAfterBuild) }
    }

    /// Whether importing a boost that carries JavaScript prompts before the script is
    /// allowed to run. On by default, and there is a real reason not to make it easy
    /// to turn off: an imported script runs inside a session the user is signed into.
    @Published var warnsBeforeTrustingImportedScripts: Bool {
        didSet {
            defaults.set(warnsBeforeTrustingImportedScripts,
                         forKey: Key.warnsBeforeTrustingImportedScripts)
        }
    }

    // Note: there is deliberately no "launch at login" here. Wrapybara is a builder,
    // not an agent — it has no reason to be running when nobody is building a wrap.
    // The apps it *builds* are ordinary applications, added to Login Items the normal
    // way.
}

import Foundation

/// Which of its two lives the binary is living.
///
/// Wrapybara ships **one** executable. A generated app's `Contents/MacOS/<Name>` is
/// a byte copy of it, and the copy decides at launch — from its *own* bundle — that
/// it is a site app rather than the builder.
///
/// Why one binary instead of an embedded helper app that gets copied out:
///
/// - A generated app keeps no reference back to Wrapybara.app, so deleting Wrapybara
///   doesn't break the apps it built.
/// - There's no nested bundle to sign, re-sign, or get wrong.
/// - One target, one build, one place for a bug to live. The cost is that every wrap
///   carries the builder's code as dead weight, which is a few megabytes — against a
///   Chromium-based wrapper's few hundred.
enum LaunchMode {

    /// The library window: creating and editing wraps.
    case builder
    /// One site, as its own app.
    case site(WrapConfiguration)

    /// Reads the running bundle and decides.
    ///
    /// The presence of `WBWrapIdentifier` in `Info.plist` is the signal — the builder's
    /// own plist has no such key, and only the exporter writes one.
    static func detect(bundle: Bundle = .main) -> LaunchMode {
        guard let identifierString = bundle.object(
                forInfoDictionaryKey: InfoPlistBuilder.Key.wrapIdentifier) as? String,
              let wrapID = UUID(uuidString: identifierString)
        else { return .builder }

        if let configuration = loadConfiguration(wrapID: wrapID, bundle: bundle) {
            return .site(configuration)
        }
        // The plist says this is a wrap but neither copy of its configuration could be
        // read. Rather than showing the builder UI from inside an app called "Proton
        // Mail", fall back to the home URL the exporter also wrote into the plist —
        // the wrap loses its boosts but still opens the site it exists to open.
        if let fallback = fallbackConfiguration(wrapID: wrapID, bundle: bundle) {
            return .site(fallback)
        }
        return .builder
    }

    /// The newer of the live configuration in the shared store and the seed baked into
    /// the bundle. See `WrapConfiguration.newer(bundled:stored:)` for why newest wins.
    static func loadConfiguration(wrapID: UUID, bundle: Bundle) -> WrapConfiguration? {
        let store = JSONFileStore()

        let stored = store.loadIfPossible(
            WrapConfiguration.self, from: AppSupport.runtimeConfigurationURL(forWrapID: wrapID))

        var bundled: WrapConfiguration?
        let fileName = (bundle.object(forInfoDictionaryKey: InfoPlistBuilder.Key.configurationFile)
            as? String) ?? InfoPlistBuilder.configurationFileName
        if let seedURL = bundle.url(forResource: (fileName as NSString).deletingPathExtension,
                                    withExtension: (fileName as NSString).pathExtension) {
            bundled = store.loadIfPossible(WrapConfiguration.self, from: seedURL)
        }

        // A configuration describing a *different* wrap can't apply here, however new
        // it is — that would be a stale store entry from a wrap that was deleted and
        // recreated, and obeying it would point this app at someone else's site.
        func forThisWrap(_ configuration: WrapConfiguration?) -> WrapConfiguration? {
            configuration?.wrap.id == wrapID ? configuration : nil
        }
        return WrapConfiguration.newer(bundled: forThisWrap(bundled), stored: forThisWrap(stored))
    }

    /// A minimal configuration assembled from `Info.plist` alone, for when both real
    /// copies are unreadable.
    static func fallbackConfiguration(wrapID: UUID, bundle: Bundle) -> WrapConfiguration? {
        guard let urlString = bundle.object(forInfoDictionaryKey: InfoPlistBuilder.Key.homeURL) as? String,
              let url = URL(string: urlString) else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? bundle.appDisplayName
        let wrap = Wrap(id: wrapID,
                        name: name,
                        homeURL: url,
                        bundleIdentifier: bundle.bundleIdentifier ?? "",
                        icon: .monogram(for: name))
        return WrapConfiguration(wrap: wrap, boosts: [],
                                 generatedBy: "recovered", generatedAt: .distantPast)
    }
}

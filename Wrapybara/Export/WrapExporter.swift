import AppKit

/// Builds a wrap into an app, and keeps already-built apps up to date.
///
/// The policy layer over `AppBundleWriter`: it decides the file name, resolves the
/// artwork, records where the app landed, and republishes the wrap's live
/// configuration.
final class WrapExporter {

    struct Outcome {
        var wrap: Wrap
        var appURL: URL
    }

    enum ExportError: LocalizedError {
        case emptyName
        case noHome

        var errorDescription: String? {
            switch self {
            case .emptyName: return "This wrap needs a name before it can be built."
            case .noHome: return "This wrap needs a web address before it can be built."
            }
        }
    }

    private let store: WrapStore
    private let preferences: Preferences
    private let writer: AppBundleWriter

    /// Composed artwork, cached per wrap.
    ///
    /// `resolvedIcon(for:)` is called for every row of the library sidebar on every
    /// SwiftUI render — which is every keystroke in any editor field. Without a cache
    /// that's a disk read and a PNG decode per row per render. The key carries the
    /// wrap's `updatedAt`, so any edit that changes the artwork (a fetch, a picked
    /// file, a rename that changes the monogram) lands under a new key. `NSCache`
    /// evicts under memory pressure with no bookkeeping of our own; the count limit
    /// bounds the growth those `updatedAt`-churned keys could otherwise achieve in a
    /// very long session — a wrap's icons are a few hundred kilobytes each, so 256
    /// entries is generous and still trivial memory.
    private let iconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        // Cost is the decoded bitmap's byte footprint (see `setObject(…cost:)`
        // below), so this is a real memory budget: 128 MB is far past any legitimate
        // library and cheap enough to give away.
        cache.totalCostLimit = 128 * 1024 * 1024
        return cache
    }()

    init(store: WrapStore,
         preferences: Preferences = .shared,
         writer: AppBundleWriter = AppBundleWriter()) {
        self.store = store
        self.preferences = preferences
        self.writer = writer
    }

    // MARK: Build

    /// Builds `wrap` into an app, updates the library, and returns where it landed.
    func build(_ wrap: Wrap) throws -> Outcome {
        guard !wrap.name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw ExportError.emptyName
        }
        guard let scheme = wrap.homeURL.scheme, !scheme.isEmpty,
              wrap.homeURL != Wrap.blankURL else {
            throw ExportError.noHome
        }

        let version = Bundle.main.shortVersionString
        let build = Bundle.main.buildVersionString
        let fileName = wrap.appFileName
        // `CFBundleExecutable` is the file name too, so a name with spaces would give
        // `Contents/MacOS/Proton Mail`. That's legal and several shipping apps do it,
        // but it makes every `ps`, crash log and `open -a` invocation awkward, so the
        // executable gets the space-free form while the bundle keeps the real name.
        let executableName = fileName.replacingOccurrences(of: " ", with: "")

        let plan = AppBundleWriter.Plan(
            destinationDirectory: preferences.installDirectory,
            appFileName: fileName,
            executableName: executableName.isEmpty ? "WrapybaraSite" : executableName,
            infoPlist: InfoPlistBuilder.plist(for: wrap,
                                              executableName: executableName.isEmpty
                                                  ? "WrapybaraSite" : executableName,
                                              version: version,
                                              buildNumber: build,
                                              generatedBy: "Wrapybara \(version)"),
            configuration: store.configuration(for: wrap),
            icon: resolvedIcon(for: wrap),
            runtimeExecutable: try runtimeExecutableURL(),
            signingIdentity: preferences.signingIdentity)

        let appURL = try writer.write(plan)

        var built = wrap
        built.installedAppPath = appURL.path
        built.installedRuntimeVersion = version
        store.update(built)
        // The bundle already carries a seed copy, but publish the live one too so the
        // app finds it in the shared store on first launch and stays in step from
        // then on without being rebuilt.
        try? store.publishRuntimeConfiguration(for: built)

        return Outcome(wrap: built, appURL: appURL)
    }

    /// Rebuilds every wrap whose installed app came from a different Wrapybara
    /// version, so a feature added to the runtime reaches apps built before it.
    ///
    /// Returns what succeeded and what didn't, rather than throwing on the first
    /// failure: one wrap whose destination has gone away shouldn't stop the other
    /// eleven from being brought up to date.
    func refreshStaleRuntimes() -> (updated: [Wrap], failures: [(wrap: Wrap, error: Error)]) {
        let version = Bundle.main.shortVersionString
        var updated: [Wrap] = []
        var failures: [(wrap: Wrap, error: Error)] = []
        for wrap in store.library.wraps where wrap.hasStaleRuntime(currentVersion: version) {
            do {
                updated.append(try build(wrap).wrap)
            } catch {
                failures.append((wrap: wrap, error: error))
            }
        }
        return (updated, failures)
    }

    // MARK: Pieces

    /// The binary to copy into the new bundle: Wrapybara's own.
    private func runtimeExecutableURL() throws -> URL {
        guard let url = Bundle.main.executableURL else {
            throw AppBundleWriter.WriteError.noRuntimeExecutable
        }
        return url
    }

    /// The artwork for `wrap`: the PNG saved next to the library if there is one,
    /// otherwise a freshly drawn monogram.
    ///
    /// Never returns `nil` — an app with no icon at all shows the generic blank page
    /// in the Dock, which is a worse outcome than initials on a plate. The returned
    /// instance is shared from a cache across callers — treat it as immutable.
    func resolvedIcon(for wrap: Wrap) -> NSImage {
        let key = "\(wrap.id.uuidString)|\(wrap.updatedAt.timeIntervalSince1970)" as NSString
        if let cached = iconCache.object(forKey: key) { return cached }
        let url = AppSupport.iconURL(forWrapID: wrap.id)
        if let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.isValid {
            // Cost is the decoded bitmap's footprint, not the PNG's byte count —
            // the cache bounds memory, and a 1024 RGBA decode is ~4 MB against a
            // few hundred KB on disk. RGBA at 4 bytes/pixel is an approximation,
            // and the right one to approximate with.
            let cost = image.representations.reduce(0) { $0 + $1.pixelsWide * $1.pixelsHigh * 4 }
            iconCache.setObject(image, forKey: key, cost: cost)
            return image
        }
        return IconComposer.monogram(WrapIcon.initials(for: wrap.name),
                                     plate: IconPlate.resolved(for: wrap.icon))
    }

    /// Saves composed artwork for `wrap` so later builds (and the library list) reuse
    /// it instead of re-fetching.
    func saveIcon(_ image: NSImage, for wrap: Wrap) throws {
        try AppSupport.createDirectory(AppSupport.iconsDirectory)
        guard let png = IcnsWriter.pngData(from: image, pixels: Int(IconComposer.canvas)) else {
            throw IcnsWriter.WriteError.renderFailed(Int(IconComposer.canvas))
        }
        try png.write(to: AppSupport.iconURL(forWrapID: wrap.id), options: [.atomic])
    }

    /// Saves the *raw* artwork, before any plate is drawn behind it, so a later
    /// plate restyle can recompose without going back to the site or the file.
    func saveArtwork(_ image: NSImage, for wrap: Wrap) throws {
        try AppSupport.createDirectory(AppSupport.iconsDirectory)
        guard let png = IcnsWriter.pngData(from: image, pixels: Int(IconComposer.canvas)) else {
            throw IcnsWriter.WriteError.renderFailed(Int(IconComposer.canvas))
        }
        try png.write(to: AppSupport.artworkURL(forWrapID: wrap.id), options: [.atomic])
    }

    /// The raw artwork saved by `saveArtwork`, if there is any.
    ///
    /// Read straight from disk each time: this only feeds the occasional
    /// recomposition after a plate edit, not a per-render path like
    /// `resolvedIcon`, so it doesn't share the icon cache.
    func artwork(for wrap: Wrap) -> NSImage? {
        guard let data = try? Data(contentsOf: AppSupport.artworkURL(forWrapID: wrap.id)),
              let image = NSImage(data: data), image.isValid else { return nil }
        return image
    }

    // MARK: Post-build actions

    /// Reveals and/or launches the app just built, per the user's preference.
    func performPostBuildActions(for appURL: URL) {
        if preferences.revealAfterBuild {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }
        if preferences.launchAfterBuild {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: appURL, configuration: configuration)
        }
    }

    /// Moves a built app to the Trash. Offered separately from deleting the library
    /// entry, because the two are genuinely different intentions.
    func moveAppToTrash(for wrap: Wrap) throws {
        guard let url = wrap.installedAppURL,
              FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        var cleared = wrap
        cleared.installedAppPath = nil
        cleared.installedRuntimeVersion = nil
        store.update(cleared)
    }
}

extension Bundle {
    /// `CFBundleVersion` (the build number), or `"1"`.
    var buildVersionString: String {
        (infoDictionary?["CFBundleVersion"] as? String) ?? "1"
    }
}

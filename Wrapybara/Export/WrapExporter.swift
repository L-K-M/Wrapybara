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
    /// in the Dock, which is a worse outcome than initials on a plate.
    func resolvedIcon(for wrap: Wrap) -> NSImage {
        let url = AppSupport.iconURL(forWrapID: wrap.id)
        if let data = try? Data(contentsOf: url), let image = NSImage(data: data), image.isValid {
            return image
        }
        return IconComposer.monogram(WrapIcon.initials(for: wrap.name),
                                     plateColor: IconComposer.plateColor(for: wrap.icon))
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

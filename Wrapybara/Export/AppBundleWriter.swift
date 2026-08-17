import AppKit

/// Assembles a real `.app` bundle on disk.
///
/// The layout is the ordinary one — `Contents/MacOS`, `Contents/Resources`,
/// `Info.plist`, `PkgInfo` — because the goal is an app macOS can't tell from one
/// built by Xcode. The only unusual thing is where the executable comes from: it's a
/// byte copy of Wrapybara's own binary, which decides at launch that it is running
/// as a site rather than as the builder (see `LaunchMode`).
///
/// That single-binary design is what makes a generated app *standalone*. It keeps no
/// reference back to Wrapybara.app, so deleting Wrapybara doesn't break the twelve
/// apps it built.
struct AppBundleWriter {

    /// Everything needed to write one bundle. Assembled by `WrapExporter`, which is
    /// where the policy lives; this type only writes files.
    struct Plan {
        /// Where the `.app` goes (`/Applications`, `~/Applications`, …).
        var destinationDirectory: URL
        /// The bundle name without `.app`.
        var appFileName: String
        /// The file name for the copied runtime inside `Contents/MacOS`. Must equal
        /// `CFBundleExecutable`, or Launch Services refuses to open the bundle.
        var executableName: String
        var infoPlist: [String: Any]
        /// The seed configuration baked into `Contents/Resources`.
        var configuration: WrapConfiguration
        /// The finished 1024×1024 icon, or `nil` to ship without one.
        var icon: NSImage?
        /// The binary to copy — normally `Bundle.main.executableURL`.
        var runtimeExecutable: URL
        /// `-` for ad-hoc, or a Developer ID common name.
        var signingIdentity: String
    }

    enum WriteError: LocalizedError {
        case noRuntimeExecutable
        case destinationNotWritable(URL)
        case replaceFailed(URL, underlying: String)

        var errorDescription: String? {
            switch self {
            case .noRuntimeExecutable:
                return "Couldn't find Wrapybara's own executable to copy into the new app."
            case .destinationNotWritable(let url):
                return "Can't write to \(url.path)."
            case .replaceFailed(let url, let underlying):
                return "Couldn't put the finished app at \(url.path): \(underlying)"
            }
        }

        var recoverySuggestion: String? {
            switch self {
            case .destinationNotWritable:
                return "Choose a different folder in Settings, or use ~/Applications."
            default:
                return nil
            }
        }
    }

    var fileManager: FileManager = .default

    /// Writes the bundle and returns where it landed.
    ///
    /// Builds into a temporary directory and swaps the result into place at the end.
    /// Two reasons: a failure halfway through never leaves a broken `.app` in
    /// `/Applications`, and replacing a wrap the user currently has *running* is a
    /// single directory swap rather than a window during which the app's own files
    /// are missing from under it.
    func write(_ plan: Plan) throws -> URL {
        guard fileManager.isReadableFile(atPath: plan.runtimeExecutable.path) else {
            throw WriteError.noRuntimeExecutable
        }
        try ensureWritable(plan.destinationDirectory)

        let staging = try makeStagingDirectory()
        defer { try? fileManager.removeItem(at: staging) }

        let app = staging.appendingPathComponent("\(plan.appFileName).app", isDirectory: true)
        try assemble(plan, at: app)

        // Sign the finished bundle, then verify — an invalid seal shows up as an app
        // that dies silently on launch, which is the worst failure to debug.
        try CodeSigner.sign(bundleAt: app, identity: plan.signingIdentity)
        try CodeSigner.verify(bundleAt: app)

        let destination = plan.destinationDirectory
            .appendingPathComponent("\(plan.appFileName).app", isDirectory: true)
        try install(app, at: destination)
        return destination
    }

    // MARK: Assembly

    private func assemble(_ plan: Plan, at app: URL) throws {
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)

        // 1. The runtime.
        let executable = macOS.appendingPathComponent(plan.executableName, isDirectory: false)
        try fileManager.copyItem(at: plan.runtimeExecutable, to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        // 2. Info.plist, as XML so anyone can read the app they just built.
        let plistData = try PropertyListSerialization.data(
            fromPropertyList: plan.infoPlist, format: .xml, options: 0)
        try plistData.write(to: contents.appendingPathComponent("Info.plist", isDirectory: false))

        // 3. PkgInfo. Vestigial, and every real app still has it.
        try Data("APPL????".utf8)
            .write(to: contents.appendingPathComponent("PkgInfo", isDirectory: false))

        // 4. Icon.
        if let icon = plan.icon {
            try IcnsWriter.write(icon, to: resources
                .appendingPathComponent("\(InfoPlistBuilder.iconFileName).icns", isDirectory: false))
        }

        // 5. The seed configuration. The runtime prefers the live copy in the shared
        //    store, but this is what makes the app work when Wrapybara is gone.
        let configurationData = try JSONFileStore.encoder.encode(plan.configuration)
        try configurationData.write(to: resources.appendingPathComponent(
            InfoPlistBuilder.configurationFileName, isDirectory: false))

        // 6. Strip inherited quarantine before signing — see `ExtendedAttributes`.
        ExtendedAttributes.removeRecursively(ExtendedAttributes.quarantine, from: app)
    }

    // MARK: Placement

    private func makeStagingDirectory() throws -> URL {
        let url = fileManager.temporaryDirectory
            .appendingPathComponent("Wrapybara-build-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Moves the staged bundle to `destination`, replacing anything already there.
    private func install(_ staged: URL, at destination: URL) throws {
        do {
            if fileManager.fileExists(atPath: destination.path) {
                // `replaceItemAt` keeps the old bundle until the new one is in place,
                // and preserves the destination's metadata.
                _ = try fileManager.replaceItemAt(destination, withItemAt: staged,
                                                  backupItemName: nil,
                                                  options: [.usingNewMetadataOnly])
            } else {
                try fileManager.moveItem(at: staged, to: destination)
            }
        } catch {
            throw WriteError.replaceFailed(destination, underlying: error.localizedDescription)
        }
        // Bump the bundle's modification date. The Dock and Finder cache an app's icon
        // aggressively, and after a rebuild that changed the icon or the name they will
        // otherwise keep showing the previous build's. (`NSWorkspace`'s
        // `noteFileSystemChanged(_:)` is the classic nudge for this and is deprecated;
        // touching the bundle is the same signal without the deprecation.)
        try? fileManager.setAttributes([.modificationDate: Date()],
                                       ofItemAtPath: destination.path)
    }

    private func ensureWritable(_ directory: URL) throws {
        if !fileManager.fileExists(atPath: directory.path) {
            // `~/Applications` doesn't exist on a fresh account until something makes
            // it, and it's the fallback when /Applications isn't writable.
            try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        guard fileManager.isWritableFile(atPath: directory.path) else {
            throw WriteError.destinationNotWritable(directory)
        }
    }
}

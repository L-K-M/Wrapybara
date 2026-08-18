import Foundation

/// Every on-disk location Wrapybara and the apps it builds share.
///
/// The folder name is the hard-coded literal `"Wrapybara"`, never anything derived
/// from `Bundle.main`. Generated apps run this same code from inside a bundle
/// called something else entirely, and they have to arrive at the same directory —
/// that shared directory is what lets a boost edited in Wrapybara reach a running
/// site app without rebuilding it.
enum AppSupport {

    static let folderName = "Wrapybara"

    /// `~/Library/Application Support/Wrapybara`.
    ///
    /// Falls back to a path under the home directory if the search-path lookup fails
    /// (it shouldn't; a sandbox would redirect rather than fail, and nothing here is
    /// sandboxed).
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent(folderName, isDirectory: true)
    }

    /// The builder's document.
    static var libraryFileURL: URL {
        directory.appendingPathComponent("library.json", isDirectory: false)
    }

    /// One resolved `WrapConfiguration` per wrap, rewritten whenever a wrap or its
    /// boosts change. This is the live copy; the one inside the app bundle is the
    /// seed. See `WrapConfiguration.newer(bundled:stored:)`.
    static var runtimeDirectory: URL {
        directory.appendingPathComponent("Runtime", isDirectory: true)
    }

    static func runtimeConfigurationURL(forWrapID id: UUID) -> URL {
        runtimeDirectory.appendingPathComponent("\(id.uuidString).json", isDirectory: false)
    }

    /// Resolved artwork, one PNG per wrap. Kept out of the JSON so the library file
    /// stays small and readable.
    static var iconsDirectory: URL {
        directory.appendingPathComponent("Icons", isDirectory: true)
    }

    static func iconURL(forWrapID id: UUID) -> URL {
        iconsDirectory.appendingPathComponent("\(id.uuidString).png", isDirectory: false)
    }

    /// The wrap's *un-composited* artwork, separate from the composed icon above.
    /// Kept so restyling the plate (colour, pattern) can redraw the icon without
    /// re-fetching or asking the user for the file again — the composed PNG has
    /// the old plate baked in and can't be un-baked.
    static func artworkURL(forWrapID id: UUID) -> URL {
        iconsDirectory.appendingPathComponent("\(id.uuidString)-artwork.png", isDirectory: false)
    }

    /// Creates `url`'s directory if it isn't there. Throwing rather than silent, so a
    /// save failure surfaces instead of losing the user's work quietly.
    static func createDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}

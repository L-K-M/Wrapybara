import XCTest
import UpdraftCore

/// Wrapybara's own use of UpdraftCore: the asset names its releases publish and the
/// download naming `DownloadCoordinator` relies on. Updraft's own suite covers the
/// general behaviour of the release model and downloader.
final class GitHubReleaseTests: XCTestCase {

    /// Per-test scratch directory so the destination tests never touch a shared
    /// location like `/tmp` (a leftover `Wrapybara.dmg` there made them flaky).
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WrapybaraReleaseTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir { try? FileManager.default.removeItem(at: tempDir) }
        tempDir = nil
    }

    private let json = Data("""
    {
      "tag_name": "v1.4.0",
      "name": "Wrapybara 1.4.0",
      "body": "Notes here",
      "html_url": "https://github.com/L-K-M/Wrapybara/releases/tag/v1.4.0",
      "prerelease": false,
      "draft": false,
      "published_at": "2026-06-01T12:00:00Z",
      "assets": [
        { "name": "Wrapybara-1.4.0-macos-universal.zip", "content_type": "application/zip", "size": 1, "browser_download_url": "https://example.com/Wrapybara.zip" },
        { "name": "Wrapybara-1.4.0-macos-universal.dmg", "content_type": "application/x-apple-diskimage", "size": 2, "browser_download_url": "https://example.com/Wrapybara.dmg" }
      ]
    }
    """.utf8)

    func testPrefersDMGForRealReleaseAssetNames() throws {
        let release = try JSONDecoder().decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.preferredAsset?.name, "Wrapybara-1.4.0-macos-universal.dmg")
    }

    func testDestinationNamingMatchesDownloadCoordinator() throws {
        // `DownloadCoordinator` pre-sanitises with this fallback before calling
        // `uniqueDestination`; a `WKDownload`'s suggested name can be anything.
        XCTAssertEqual(try destinationName(for: ".."), "Wrapybara-update")
        XCTAssertEqual(try destinationName(for: "../../Wrapybara.dmg"), "Wrapybara.dmg")
        XCTAssertEqual(try destinationName(for: "Wrapybara\u{0000}.zip"), "Wrapybara-.zip")
    }

    func testDestinationSkipsExistingFilesAndDanglingSymlinks() throws {
        // An empty directory hands back the plain name.
        XCTAssertEqual(try destinationName(for: "Wrapybara.dmg"), "Wrapybara.dmg")

        // With Wrapybara.dmg and Wrapybara-1.dmg taken, the -2/-3 suffixing kicks in.
        try Data().write(to: tempDir.appendingPathComponent("Wrapybara.dmg"))
        try Data().write(to: tempDir.appendingPathComponent("Wrapybara-1.dmg"))
        XCTAssertEqual(try destinationName(for: "Wrapybara.dmg"), "Wrapybara-2.dmg")

        // A dangling symlink at the next candidate still counts as "taken":
        // fileExists(atPath:) follows the link and would report false, letting the
        // link be reused as a destination. lstat semantics must skip past it.
        try FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent("Wrapybara-2.dmg"),
            withDestinationURL: tempDir.appendingPathComponent("does-not-exist.dmg")
        )
        XCTAssertEqual(try destinationName(for: "Wrapybara.dmg"), "Wrapybara-3.dmg")
    }

    /// Mirrors `DownloadCoordinator.destination(for:)`: pre-sanitise with Wrapybara's
    /// fallback, then let Updraft pick a non-colliding name.
    private func destinationName(for suggestedFilename: String) throws -> String {
        let fileName = UpdateDownloader.sanitizedFileName(suggestedFilename,
                                                          fallback: "Wrapybara-update")
        return try UpdateDownloader.uniqueDestination(in: tempDir,
                                                      fileName: fileName).lastPathComponent
    }
}

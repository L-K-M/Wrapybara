import XCTest
@testable import Wrapybara

final class GitHubReleaseTests: XCTestCase {

    /// Per-test scratch directory so the `uniqueDestination` tests never touch a
    /// shared location like `/tmp` (a leftover `Wrapybara.dmg` there made them flaky).
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
        { "name": "Wrapybara-1.4.0.zip", "content_type": "application/zip", "size": 1, "browser_download_url": "https://example.com/Wrapybara.zip" },
        { "name": "Wrapybara-1.4.0.dmg", "content_type": "application/x-apple-diskimage", "size": 2, "browser_download_url": "https://example.com/Wrapybara.dmg" }
      ]
    }
    """.utf8)

    func testDecodes() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.tagName, "v1.4.0")
        XCTAssertEqual(release.assets.count, 2)
        XCTAssertFalse(release.draft)
    }

    func testPrefersDMGAsset() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.preferredAsset?.name, "Wrapybara-1.4.0.dmg")
    }

    func testReleaseNotesTruncates() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let release = try decoder.decode(GitHubRelease.self, from: json)
        XCTAssertEqual(release.releaseNotes(maxLength: 4), "Note…")
    }

    func testUpdateDownloaderSanitizesAssetNames() throws {
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: tempDir, fileName: "../../Wrapybara.dmg").lastPathComponent,
            "Wrapybara.dmg"
        )
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: tempDir, fileName: "Wrapybara\u{0000}.zip").lastPathComponent,
            "Wrapybara-.zip"
        )
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: tempDir, fileName: "..").lastPathComponent,
            "Wrapybara-update"
        )
    }

    func testUniqueDestinationSkipsExistingFilesAndDanglingSymlinks() throws {
        // An empty directory hands back the plain name.
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: tempDir, fileName: "Wrapybara.dmg").lastPathComponent,
            "Wrapybara.dmg"
        )

        // With Wrapybara.dmg and Wrapybara-1.dmg taken, the -2/-3 suffixing kicks in.
        try Data().write(to: tempDir.appendingPathComponent("Wrapybara.dmg"))
        try Data().write(to: tempDir.appendingPathComponent("Wrapybara-1.dmg"))
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: tempDir, fileName: "Wrapybara.dmg").lastPathComponent,
            "Wrapybara-2.dmg"
        )

        // A dangling symlink at the next candidate still counts as "taken":
        // fileExists(atPath:) follows the link and would report false, letting the
        // link be reused as a destination. lstat semantics must skip past it.
        try FileManager.default.createSymbolicLink(
            at: tempDir.appendingPathComponent("Wrapybara-2.dmg"),
            withDestinationURL: tempDir.appendingPathComponent("does-not-exist.dmg")
        )
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: tempDir, fileName: "Wrapybara.dmg").lastPathComponent,
            "Wrapybara-3.dmg"
        )
    }

    func testUniqueDestinationThrowsWhenAttemptCapIsExhausted() throws {
        try Data().write(to: tempDir.appendingPathComponent("Wrapybara.dmg"))
        try Data().write(to: tempDir.appendingPathComponent("Wrapybara-1.dmg"))
        try Data().write(to: tempDir.appendingPathComponent("Wrapybara-2.dmg"))

        XCTAssertThrowsError(
            try UpdateDownloader.uniqueDestination(in: tempDir, fileName: "Wrapybara.dmg", maxAttempts: 2)
        ) { error in
            guard case UpdateDownloader.DownloadError.noUniqueFileName(_, let fileName, let attempts) = error else {
                return XCTFail("Expected noUniqueFileName, got \(error)")
            }
            XCTAssertEqual(fileName, "Wrapybara.dmg")
            XCTAssertEqual(attempts, 2)
        }

        // The default cap is far beyond any real Downloads folder.
        XCTAssertEqual(
            try UpdateDownloader.uniqueDestination(in: tempDir, fileName: "Wrapybara.dmg").lastPathComponent,
            "Wrapybara-3.dmg"
        )
    }

    func testDownloadedAssetSizeValidation() throws {
        let file = tempDir.appendingPathComponent("Wrapybara.dmg")
        try Data([0, 1, 2, 3]).write(to: file)

        XCTAssertNoThrow(try UpdateDownloader.validateDownloadedFile(at: file, expectedSize: 4))
        XCTAssertThrowsError(
            try UpdateDownloader.validateDownloadedFile(at: file, expectedSize: 5)
        ) { error in
            guard case UpdateDownloader.DownloadError.sizeMismatch(let expected, let actual) = error else {
                return XCTFail("Expected sizeMismatch, got \(error)")
            }
            XCTAssertEqual(expected, 5)
            XCTAssertEqual(actual, 4)
        }
        XCTAssertThrowsError(
            try UpdateDownloader.validateDownloadedFile(at: file, expectedSize: 3)
        )
    }
}

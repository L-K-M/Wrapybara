import AppKit
import WebKit

/// Handles downloads the way a Mac app does: into `~/Downloads`, with a bouncing
/// Dock progress and a Finder reveal when it's done.
///
/// A wrapper that silently drops a download — or worse, navigates to it and shows
/// binary garbage — is the other classic tell that you're not in a real app. WebKit
/// gives us `WKDownload`; all the placement, naming and reporting is ours.
final class DownloadCoordinator: NSObject {

    /// How the finished download is announced.
    enum Completion {
        case revealInFinder
        case openWithDefaultApp
        case doNothing
    }

    var completion: Completion = .revealInFinder

    /// Live downloads, keyed by the `WKDownload` that owns them, so progress can be
    /// attributed and the delegate can be dropped when it finishes.
    private var active: [ObjectIdentifier: Entry] = [:]

    private struct Entry {
        var download: WKDownload
        var destination: URL?
        var progress: Progress
        /// `Progress.publish()` is what puts a transfer in the Dock's progress
        /// indicator and Finder's Downloads stack — but it can only be called once the
        /// destination is known, and `unpublish()` must not be called without it.
        var isPublished = false
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        super.init()
    }

    /// Takes over a download WebKit just handed us.
    func begin(_ download: WKDownload) {
        download.delegate = self
        // `Progress` published this way is what puts the download in the Dock's
        // progress indicator and in Finder's "Downloads" stack, for free.
        let progress = Progress(totalUnitCount: -1)
        progress.kind = .file
        progress.fileOperationKind = .downloading
        progress.isCancellable = true
        progress.cancellationHandler = { download.cancel() }
        active[ObjectIdentifier(download)] = Entry(download: download, destination: nil,
                                                   progress: progress)
    }

    var activeCount: Int { active.count }

    /// Cancels everything in flight. Called when the app is asked to quit mid-download
    /// and the user says go ahead.
    func cancelAll() {
        for entry in active.values { entry.download.cancel() }
        active.removeAll()
    }

    // MARK: Placement

    /// The URL to save `suggestedFilename` at, inside the Downloads folder, without
    /// clobbering anything.
    ///
    /// Reuses `UpdateDownloader`'s collision logic rather than reimplementing it: the
    /// `Foo.dmg` → `Foo-1.dmg` walk, the sanitising of a server-supplied name, and the
    /// dangling-symlink-aware existence check are all the same problem.
    func destination(for suggestedFilename: String) throws -> URL {
        let downloads = try fileManager.url(for: .downloadsDirectory, in: .userDomainMask,
                                            appropriateFor: nil, create: true)
        return try UpdateDownloader.uniqueDestination(in: downloads,
                                                      fileName: suggestedFilename,
                                                      fileManager: fileManager)
    }
}

// MARK: - WKDownloadDelegate

extension DownloadCoordinator: WKDownloadDelegate {

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        do {
            let url = try destination(for: suggestedFilename)
            let key = ObjectIdentifier(download)
            active[key]?.destination = url
            if response.expectedContentLength > 0 {
                active[key]?.progress.totalUnitCount = response.expectedContentLength
            }
            active[key]?.progress.fileURL = url
            active[key]?.progress.publish()
            active[key]?.isPublished = true
            completionHandler(url)
        } catch {
            present(error, title: "Couldn't start the download")
            completionHandler(nil)
            finish(download)
        }
    }

    func download(_ download: WKDownload, didReceive challenge: URLAuthenticationChallenge,
                  completionHandler: @escaping (URLSession.AuthChallengeDisposition,
                                                URLCredential?) -> Void) {
        // No credential of our own to offer, and no reason to override the system's
        // trust evaluation for a file transfer.
        completionHandler(.performDefaultHandling, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let destination = active[ObjectIdentifier(download)]?.destination
        finish(download)
        guard let destination else { return }
        switch completion {
        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        case .openWithDefaultApp:
            NSWorkspace.shared.open(destination)
        case .doNothing:
            break
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error,
                  resumeData: Data?) {
        finish(download)
        let nsError = error as NSError
        // A cancelled download is a user action, not a failure to report back to them.
        guard !(nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled) else {
            return
        }
        present(error, title: "Download failed")
    }

    private func finish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        // Unpublish so the Dock indicator doesn't stall at whatever fraction the
        // transfer stopped at.
        active[key]?.progress.cancellationHandler = nil
        if active[key]?.isPublished == true { active[key]?.progress.unpublish() }
        active[key] = nil
    }

    private func present(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

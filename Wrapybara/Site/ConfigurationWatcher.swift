import Foundation

/// Watches a site app's configuration file so a boost edited in Wrapybara reaches a
/// *running* app.
///
/// It watches the **directory**, not the file. Configurations are written atomically
/// (`JSONFileStore`), which replaces the file rather than modifying it — a vnode source
/// on the file itself would go deaf after the first save, because the descriptor it
/// holds points at the old, now-unlinked inode.
final class ConfigurationWatcher {

    /// Called on the main queue when the configuration may have changed. The caller
    /// re-reads and decides whether anything actually differs.
    var onChange: (() -> Void)?

    private let directory: URL
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var coalesceWorkItem: DispatchWorkItem?

    /// File-system events arrive in bursts (a temporary file appears, then the rename
    /// lands). Coalescing means one re-read per save instead of three.
    private let coalesceInterval: TimeInterval = 0.15

    init(directory: URL) {
        self.directory = directory
    }

    deinit { stop() }

    func start() {
        guard source == nil else { return }
        // The directory has to exist before it can be watched, and on a first run it
        // won't — Wrapybara creates it when it first publishes.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else {
            NSLog("Wrapybara: couldn't watch \(directory.path) for boost changes")
            return
        }
        descriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete],
            queue: .main)
        source.setEventHandler { [weak self] in self?.scheduleChange() }
        source.setCancelHandler { [weak self] in
            guard let self, self.descriptor >= 0 else { return }
            close(self.descriptor)
            self.descriptor = -1
        }
        source.resume()
        self.source = source
    }

    func stop() {
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        source?.cancel()
        source = nil
    }

    private func scheduleChange() {
        coalesceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange?() }
        coalesceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceInterval, execute: work)
    }
}

import AppKit

/// The app delegate Wrapybara itself runs under.
final class BuilderAppDelegate: NSObject, NSApplicationDelegate {

    private let store = WrapStore()
    private let preferences = Preferences.shared
    private lazy var exporter = WrapExporter(store: store, preferences: preferences)
    private lazy var library = LibraryWindowController(store: store,
                                                      exporter: exporter,
                                                      preferences: preferences)
    private let updateChecker = UpdateChecker(
        configuration: .init(owner: "L-K-M", repo: "Wrapybara", appName: "Wrapybara")
    )

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        NSApp.mainMenu = BuilderMenuBuilder.mainMenu(target: self)
        library.showWindow(nil)
        updateChecker.start()

        // Re-publish every wrap's configuration on launch. After a Wrapybara upgrade
        // this is what gets configurations written by the current format in front of
        // apps built by the previous one, without waiting for the user to edit
        // something.
        store.publishAllRuntimeConfigurations()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        library.showWindow(nil)
        return true
    }

    /// The library window *is* the app; closing it should quit, the way a
    /// single-window utility does.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        guard !Self.isRunningTests else { return }
        store.flush()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// Dropping a `.wrapyboost` file on the Dock icon imports it.
    func application(_ application: NSApplication, open urls: [URL]) {
        library.showWindow(nil)
        library.importBoosts(from: urls)
    }

    // MARK: Menu actions

    @objc func newWrap(_ sender: Any?) {
        library.showWindow(nil)
        library.beginNewWrap()
    }

    @objc func showLibrary(_ sender: Any?) {
        library.showWindow(nil)
    }

    @objc func showSettings(_ sender: Any?) {
        library.showWindow(nil)
        library.showSettings()
    }

    @objc func checkForUpdates(_ sender: Any?) {
        updateChecker.checkNow()
    }

    @objc func buildSelectedWrap(_ sender: Any?) {
        library.buildSelectedWrap()
    }

    @objc func refreshStaleRuntimes(_ sender: Any?) {
        library.refreshStaleRuntimes()
    }

    @objc func showHelp(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/L-K-M/Wrapybara#readme") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func showAbout(_ sender: Any?) {
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    // MARK: Helpers

    static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

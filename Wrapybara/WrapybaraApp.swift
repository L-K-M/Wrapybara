import AppKit

/// Program entry point for both of the binary's lives.
///
/// One executable serves as the builder and as every app it builds; `LaunchMode`
/// decides which, by reading the running bundle's `Info.plist`. See `LaunchMode` for
/// why it's one binary and not two.
@main
enum WrapybaraMain {

    /// `NSApplication.delegate` is a weak reference, so the delegate needs an owner
    /// that outlives `main()`.
    private static var delegate: NSApplicationDelegate?

    static func main() {
        let app = NSApplication.shared

        switch LaunchMode.detect() {
        case .builder:
            delegate = BuilderAppDelegate()
        case .site(let configuration):
            delegate = SiteAppDelegate(configuration: configuration)
        }

        app.delegate = delegate
        // Both modes are ordinary apps with a Dock icon and a menu bar. A wrap that
        // hid in the menu bar wouldn't be the "real Mac app" this is for.
        app.setActivationPolicy(.regular)
        app.run()
    }
}

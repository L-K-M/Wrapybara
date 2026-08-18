import AppKit

/// A transparent strip across the top of a chrome-less window that puts back the
/// one piece of title bar a window can't do without: somewhere to grab.
///
/// With "No chrome" the page runs edge to edge under a transparent title bar, and
/// a `WKWebView` answers every mouse event in that strip itself — so no pixel of
/// the window's top edge moves it. This view sits above the web view (and below
/// the find bar, which owns the strip's region while it's open) and opts into
/// window dragging. Double-click honours the system title-bar setting, as the
/// real title bar would.
final class WindowDragStrip: NSView {

    /// What the window consults on a mouse-down: `true` means a drag from here
    /// moves the window. The view still receives `mouseDown` — which is what the
    /// double-click handling below hangs off.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Take the activating click too, so an unfocused window drags on the first
    /// grab, the way its title bar does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let window else { return }
        // The same default the title bar reads: "Minimize", "Maximize" or "None".
        // An unset value means Maximize — the factory setting.
        switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
        case "Minimize": window.performMiniaturize(nil)
        case "None": break
        default: window.performZoom(nil)
        }
    }
}

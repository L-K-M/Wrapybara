import AppKit

/// A transparent strip across the top of a chrome-less window that puts back the
/// two pieces of title bar a window can't do without: somewhere to grab, and the
/// window's name.
///
/// With "No chrome" the page runs edge to edge under a transparent title bar, and
/// a `WKWebView` answers every mouse event in that strip itself — so no pixel of
/// the window's top edge moves it. This view sits above the web view (and below
/// the find bar, which owns the strip's region while it's open) and opts into
/// window dragging. Double-click honours the system title-bar setting, as the
/// real title bar would.
///
/// The title is drawn here rather than left to the system because the system's
/// title text field lives in the title-bar overlay, *above* this strip: a click
/// on the rendered name would land there and die instead of dragging. With the
/// rendered title hidden (`SiteWindowController` sets `titleVisibility = .hidden`),
/// the strip owns every pixel of the band outside the traffic lights, and the
/// name is as good a place to grab as the rest of the strip.
final class WindowDragStrip: NSView {

    /// What the window consults on a mouse-down: `true` means a drag from here
    /// moves the window. The view still receives `mouseDown` — which is what the
    /// double-click handling below hangs off.
    override var mouseDownCanMoveWindow: Bool { true }

    /// Take the activating click too, so an unfocused window drags on the first
    /// grab, the way its title bar does.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Text draws from the top down; flipping makes the centering math in
    /// `draw` read the way it behaves.
    override var isFlipped: Bool { true }

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

    // MARK: Title

    /// Gap kept between the traffic lights and the title, the size the system
    /// title keeps after the buttons.
    private static let gapAfterButtons: CGFloat = 16
    /// Leading inset for when the buttons' frames can't be read (mid full-screen
    /// transition). Clears the traffic-light cluster with room to spare on every
    /// current macOS.
    private static let fallbackLeadingInset: CGFloat = 80
    /// Room kept at the trailing edge before the title truncates.
    private static let trailingMargin: CGFloat = 12

    /// The title starts clear of the traffic lights, read from the buttons
    /// themselves so a change in their metrics moves the title with them.
    private var titleLeadingX: CGFloat {
        guard let zoom = window?.standardWindowButton(.zoomButton) else {
            return Self.fallbackLeadingInset
        }
        let buttonsEnd = convert(zoom.frame, from: zoom.superview).maxX
        return buttonsEnd > 0 ? buttonsEnd + Self.gapAfterButtons
                              : Self.fallbackLeadingInset
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let window else { return }
        // A tab group's tab bar owns this band while the window is merged into
        // one; drawing under it would double up with the tab titles.
        guard (window.tabbedWindows?.count ?? 1) <= 1 else { return }
        let title = window.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }

        // Truncates with an ellipsis rather than wrapping: the strip is one line
        // tall, and a page title is allowed to be longer than it.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: title, attributes: [
            .font: NSFont.titleBarFont(ofSize: NSFont.systemFontSize),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: paragraph,
        ])

        let leadingX = titleLeadingX
        let width = bounds.width - leadingX - Self.trailingMargin
        guard width > 0 else { return }
        let textSize = text.boundingRect(
            with: NSSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin], context: nil).size

        text.draw(with: NSRect(x: leadingX,
                               y: (bounds.height - textSize.height) / 2,
                               width: width,
                               height: textSize.height),
                  options: [.usesLineFragmentOrigin], context: nil)
    }
}

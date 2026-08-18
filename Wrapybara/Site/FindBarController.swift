import AppKit
import WebKit

/// The ⌘F find bar.
///
/// Uses WebKit's own `find(_:configuration:)` — the same search the page would get in
/// Safari, with WebKit's highlighting and scroll-into-view — rather than a JavaScript
/// text walk, which would fight the page's own DOM and miss shadow roots.
///
/// The bar is an ordinary `NSView` the window slots above the web view, styled to sit
/// under the toolbar the way `NSTextFinder`'s does. It isn't `NSTextFinder` itself:
/// that drives an `NSTextView`, and a web view isn't one.
final class FindBarController: NSObject {

    /// The bar to install in the window's layout. Hidden until `show()`.
    let view: NSView

    private weak var webView: WKWebView?
    private let searchField = NSSearchField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let previousButton = NSButton()
    private let nextButton = NSButton()
    private let doneButton = NSButton()

    /// The last string searched, so ⌘G can repeat it without the bar being focused.
    private var lastQuery = ""

    /// Whether ⌘G/⇧⌘G have something to repeat — used by menu validation, so a
    /// repeat search works without reopening the bar, the way Safari's does.
    /// `lastQuery` is the single source of truth: search-as-you-type keeps it in
    /// step with the field.
    var canRepeatFind: Bool {
        !lastQuery.isEmpty
    }

    /// Collapses the bar to zero height while hidden.
    ///
    /// `isHidden` alone is not enough: a hidden view still contributes its intrinsic
    /// size to Auto Layout, so the web view would sit permanently 33 points lower with
    /// an invisible gap above it.
    private lazy var collapsedHeight: NSLayoutConstraint = {
        let constraint = view.heightAnchor.constraint(equalToConstant: 0)
        // Just under required, so it can't fight the stack's own content constraints
        // into an unsatisfiable layout while the bar is on its way in or out.
        constraint.priority = NSLayoutConstraint.Priority(999)
        return constraint
    }()

    init(webView: WKWebView) {
        self.webView = webView
        let container = NSView()
        self.view = container
        super.init()
        build(in: container)
        container.isHidden = true
        collapsedHeight.isActive = true
    }

    var isVisible: Bool { !view.isHidden }

    // MARK: Presentation

    func show() {
        collapsedHeight.isActive = false
        view.isHidden = false
        // Pre-fill from the selection, the way every Mac app does, so ⌘F after
        // selecting a word searches for that word.
        webView?.evaluateJavaScript("String(window.getSelection())") { [weak self] result, _ in
            guard let self else { return }
            if let selection = result as? String {
                let trimmed = selection.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty, trimmed.count < 100 { self.searchField.stringValue = trimmed }
            }
            self.view.window?.makeFirstResponder(self.searchField)
            self.searchField.selectText(nil)
        }
    }

    func hide() {
        view.isHidden = true
        collapsedHeight.isActive = true
        statusLabel.stringValue = ""
        // Clear WebKit's highlight, and hand focus back to the page so typing goes
        // where the user expects.
        webView?.evaluateJavaScript("window.getSelection().removeAllRanges()",
                                    completionHandler: nil)
        if let webView { view.window?.makeFirstResponder(webView) }
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    // MARK: Searching

    @objc private func searchFieldChanged() {
        // Keep `lastQuery` in step even when the field is cleared: ⌘G must not
        // repeat a query the user deliberately erased (the empty-string early
        // return in `find` would otherwise leave the old value in place).
        lastQuery = searchField.stringValue
        find(forward: true, fromUserTyping: true)
    }

    @objc func findNext() { find(forward: true, fromUserTyping: false) }
    @objc func findPrevious() { find(forward: false, fromUserTyping: false) }
    @objc private func done() { hide() }

    /// Runs a search. `fromUserTyping` distinguishes incremental search (which should
    /// start from the top of the document) from ⌘G (which continues from the current
    /// match).
    private func find(forward: Bool, fromUserTyping: Bool) {
        guard let webView else { return }
        let query = fromUserTyping ? searchField.stringValue : (searchField.stringValue.isEmpty
            ? lastQuery : searchField.stringValue)
        guard !query.isEmpty else {
            statusLabel.stringValue = ""
            return
        }
        lastQuery = query

        let configuration = WKFindConfiguration()
        configuration.backwards = !forward
        configuration.caseSensitive = false
        configuration.wraps = true

        webView.find(query, configuration: configuration) { [weak self] result in
            guard let self else { return }
            // `WKFindResult` reports only whether anything matched — WebKit exposes no
            // match count — so the status line says "not found" or nothing rather than
            // inventing an "n of m".
            self.statusLabel.stringValue = result.matchFound ? "" : "Not found"
            self.statusLabel.textColor = result.matchFound ? .secondaryLabelColor : .systemRed
            // Beep only on an explicit repeat action (⌘G/⇧⌘G, the chevron
            // buttons) — everything typed or returned through the field arrives
            // with `fromUserTyping` true, and beeping per keystroke while a word's
            // early prefixes match nothing is what gets a find bar muted forever.
            if !result.matchFound, !fromUserTyping { NSSound.beep() }
        }
    }

    // MARK: Layout

    private func build(in container: NSView) {
        container.wantsLayer = true
        container.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .titlebar
        background.blendingMode = .withinWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(background)

        searchField.placeholderString = "Find on page"
        searchField.target = self
        searchField.action = #selector(searchFieldChanged)
        // Lets Esc close the bar — see the delegate extension below.
        searchField.delegate = self
        // Search as you type, like Safari.
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false

        configure(previousButton, symbol: "chevron.up", tooltip: "Previous match",
                  action: #selector(findPrevious))
        configure(nextButton, symbol: "chevron.down", tooltip: "Next match",
                  action: #selector(findNext))

        doneButton.title = "Done"
        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(done)

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [searchField, statusLabel, previousButton, nextButton, doneButton])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        NSLayoutConstraint.activate([
            background.topAnchor.constraint(equalTo: container.topAnchor),
            background.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            background.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: separator.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            searchField.widthAnchor.constraint(greaterThanOrEqualTo: container.widthAnchor,
                                               multiplier: 0.3),
        ])
    }

    private func configure(_ button: NSButton, symbol: String, tooltip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        button.bezelStyle = .rounded
        button.imagePosition = .imageOnly
        button.toolTip = tooltip
        button.target = self
        button.action = action
    }
}

// MARK: - Search field delegate

extension FindBarController: NSSearchFieldDelegate {

    /// Esc closes the bar. Scoped to the field on purpose: a global Esc would steal
    /// the key from the page whenever the bar happened to be open.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard command == #selector(NSResponder.cancelOperation(_:)) else { return false }
        // Mid-IME composition, Esc belongs to the input method (it cancels the
        // composition); the field editor normally consumes it first, but don't
        // close the bar out from under an active marked-text session either way.
        guard !textView.hasMarkedText() else { return false }
        hide()
        return true
    }
}

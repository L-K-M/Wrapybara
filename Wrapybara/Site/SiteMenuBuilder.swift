import AppKit

/// Builds a site app's menu bar.
///
/// This file is a large part of why a wrap feels like an app rather than a web page in
/// a frame. Every menu a Mac user reaches for is here, with the shortcut they expect:
/// ⌘R reloads, ⌘L asks for an address, ⌘F finds, ⌘0 resets zoom, ⌘[ goes back, ⌘T makes
/// a tab, Window has Merge All Windows. Nothing is a stub — each item routes to a real
/// action on `SiteWindowController` or the app delegate.
///
/// Actions are dispatched with `target: nil`, so AppKit walks the responder chain and
/// the *front* window handles them. That's what makes the same ⌘R work in every tab
/// without the menu having to know which one is showing.
enum SiteMenuBuilder {

    static func mainMenu(appName: String, wrap: Wrap, target: SiteAppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(appMenu(appName: appName, target: target))
        menu.addItem(fileMenu(appName: appName, wrap: wrap, target: target))
        menu.addItem(editMenu())
        menu.addItem(viewMenu())
        menu.addItem(historyMenu())
        menu.addItem(windowMenu())
        menu.addItem(helpMenu(appName: appName, target: target))
        return menu
    }

    // MARK: App

    private static func appMenu(appName: String, target: SiteAppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: appName)

        add(menu, "About \(appName)", #selector(SiteAppDelegate.showAbout(_:)), target: target)
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(SiteAppDelegate.showSettings(_:)), ",", target: target)
        menu.addItem(.separator())
        add(menu, "Edit Boosts in Wrapybara…",
            #selector(SiteAppDelegate.openWrapybaraForThisWrap(_:)), target: target)
        menu.addItem(.separator())

        // The Services menu has to be handed to AppKit explicitly, or Look Up,
        // Translate and every third-party service silently don't work on selected text.
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu()
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())

        add(menu, "Hide \(appName)", #selector(NSApplication.hide(_:)), "h")
        let hideOthers = add(menu, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        add(menu, "Show All", #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        add(menu, "Quit \(appName)", #selector(NSApplication.terminate(_:)), "q")

        item.submenu = menu
        return item
    }

    // MARK: File

    private static func fileMenu(appName: String, wrap: Wrap, target: SiteAppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")

        add(menu, "New Window", #selector(SiteAppDelegate.newWindow(_:)), "n", target: target)
        if wrap.behavior.allowsNativeTabs {
            add(menu, "New Tab", #selector(SiteAppDelegate.newTab(_:)), "t", target: target)
        }
        add(menu, "Open Location…", #selector(SiteWindowController.openLocation(_:)), "l")
        menu.addItem(.separator())
        add(menu, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        menu.addItem(.separator())
        add(menu, "Share…", #selector(SiteWindowController.sharePage(_:)))
        add(menu, "Copy Address", #selector(SiteWindowController.copyPageAddress(_:)))
        menu.addItem(.separator())
        add(menu, "Print…", #selector(SiteWindowController.printPage(_:)), "p")

        item.submenu = menu
        return item
    }

    // MARK: Edit

    /// The standard Edit menu.
    ///
    /// Selectors are built with `NSSelectorFromString` because the responder that
    /// implements them is WebKit's, not a type this target can see — so `#selector`
    /// genuinely isn't available, and this is the API for "known by name only".
    ///
    /// Without this menu a web view gets no ⌘C at all: AppKit routes those through menu
    /// key equivalents, not through the view. A text field in a wrapper that can't copy
    /// is the single most common bug in apps like these.
    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")

        add(menu, "Undo", NSSelectorFromString("undo:"), "z")
        let redo = add(menu, "Redo", NSSelectorFromString("redo:"), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        add(menu, "Cut", NSSelectorFromString("cut:"), "x")
        add(menu, "Copy", NSSelectorFromString("copy:"), "c")
        add(menu, "Paste", NSSelectorFromString("paste:"), "v")
        let pasteMatch = add(menu, "Paste and Match Style",
                             NSSelectorFromString("pasteAsPlainText:"), "v")
        pasteMatch.keyEquivalentModifierMask = [.command, .option, .shift]
        add(menu, "Delete", NSSelectorFromString("delete:"))
        add(menu, "Select All", NSSelectorFromString("selectAll:"), "a")
        menu.addItem(.separator())

        let find = NSMenuItem(title: "Find", action: nil, keyEquivalent: "")
        let findMenu = NSMenu(title: "Find")
        add(findMenu, "Find…", #selector(SiteWindowController.performFind(_:)), "f")
        add(findMenu, "Find Next", #selector(SiteWindowController.findNext(_:)), "g")
        let findPrevious = add(findMenu, "Find Previous",
                               #selector(SiteWindowController.findPrevious(_:)), "g")
        findPrevious.keyEquivalentModifierMask = [.command, .shift]
        find.submenu = findMenu
        menu.addItem(find)

        // Spelling and substitutions come free from the text system once the submenu
        // exists, and web forms are text fields like any other.
        let spelling = NSMenuItem(title: "Spelling and Grammar", action: nil, keyEquivalent: "")
        let spellingMenu = NSMenu(title: "Spelling and Grammar")
        add(spellingMenu, "Show Spelling and Grammar", NSSelectorFromString("showGuessPanel:"), ":")
        add(spellingMenu, "Check Document Now", NSSelectorFromString("checkSpelling:"), ";")
        spelling.submenu = spellingMenu
        menu.addItem(spelling)

        item.submenu = menu
        return item
    }

    // MARK: View

    private static func viewMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "View")

        add(menu, "Reload Page", #selector(SiteWindowController.reloadPage(_:)), "r")
        let hardReload = add(menu, "Reload Page Ignoring Cache",
                             #selector(SiteWindowController.reloadPageIgnoringCache(_:)), "r")
        hardReload.keyEquivalentModifierMask = [.command, .shift]
        add(menu, "Stop Loading", #selector(SiteWindowController.stopLoading(_:)), ".")
        menu.addItem(.separator())

        add(menu, "Actual Size", #selector(SiteWindowController.actualSize(_:)), "0")
        add(menu, "Zoom In", #selector(SiteWindowController.zoomIn(_:)), "+")
        add(menu, "Zoom Out", #selector(SiteWindowController.zoomOut(_:)), "-")
        menu.addItem(.separator())

        add(menu, "Boosts on This Page…", #selector(SiteWindowController.toggleBoostsInfo(_:)))
        menu.addItem(.separator())

        let toggleToolbar = add(menu, "Hide Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t")
        toggleToolbar.keyEquivalentModifierMask = [.command, .option]
        add(menu, "Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        menu.addItem(.separator())
        let fullScreen = add(menu, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f")
        fullScreen.keyEquivalentModifierMask = [.command, .control]

        // No "Show Web Inspector" item: WebKit exposes no public API to open the
        // inspector, only `WKWebView.isInspectable` to allow it. With that on (a
        // per-wrap setting), the inspector is reached the documented way — right-click
        // → Inspect Element. A menu item here would have nothing to call.

        item.submenu = menu
        return item
    }

    // MARK: History

    private static func historyMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "History")

        let back = add(menu, "Back", #selector(SiteWindowController.goBack(_:)), "[")
        back.keyEquivalentModifierMask = [.command]
        let forward = add(menu, "Forward", #selector(SiteWindowController.goForward(_:)), "]")
        forward.keyEquivalentModifierMask = [.command]
        menu.addItem(.separator())
        let home = add(menu, "Home", #selector(SiteWindowController.goHome(_:)), "H")
        home.keyEquivalentModifierMask = [.command, .shift]

        item.submenu = menu
        return item
    }

    // MARK: Window

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")

        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        // AppKit inserts the tab items (Show Next Tab, Move Tab to New Window, …) into
        // whichever menu is `NSApp.windowsMenu`, so setting that below is what makes
        // native tabs fully keyboard-navigable.
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))

        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    // MARK: Help

    private static func helpMenu(appName: String, target: SiteAppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        add(menu, "\(appName) Help", #selector(SiteAppDelegate.showHelp(_:)), "?", target: target)
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }

    // MARK: Building blocks

    /// Adds an item. A `nil` target means "walk the responder chain", which is what
    /// every page action wants so the front tab handles it.
    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            _ keyEquivalent: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        menu.addItem(item)
        return item
    }
}

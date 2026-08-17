import AppKit

/// Wrapybara's own menu bar.
///
/// Smaller than a site app's — there's no page to reload — but the Edit menu still has
/// to be here or the text fields in the boost editor lose ⌘C, ⌘V and ⌘Z.
enum BuilderMenuBuilder {

    static func mainMenu(target: BuilderAppDelegate) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(appMenu(target: target))
        menu.addItem(fileMenu(target: target))
        menu.addItem(editMenu())
        menu.addItem(windowMenu())
        menu.addItem(helpMenu(target: target))
        return menu
    }

    private static func appMenu(target: BuilderAppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Wrapybara")
        add(menu, "About Wrapybara", #selector(BuilderAppDelegate.showAbout(_:)), target: target)
        add(menu, "Check for Updates…", #selector(BuilderAppDelegate.checkForUpdates(_:)),
            target: target)
        menu.addItem(.separator())
        add(menu, "Settings…", #selector(BuilderAppDelegate.showSettings(_:)), ",", target: target)
        menu.addItem(.separator())
        add(menu, "Hide Wrapybara", #selector(NSApplication.hide(_:)), "h")
        let hideOthers = add(menu, "Hide Others",
                             #selector(NSApplication.hideOtherApplications(_:)), "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(.separator())
        add(menu, "Quit Wrapybara", #selector(NSApplication.terminate(_:)), "q")
        item.submenu = menu
        return item
    }

    private static func fileMenu(target: BuilderAppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "File")
        add(menu, "New Wrap…", #selector(BuilderAppDelegate.newWrap(_:)), "n", target: target)
        menu.addItem(.separator())
        add(menu, "Build Selected Wrap", #selector(BuilderAppDelegate.buildSelectedWrap(_:)), "b",
            target: target)
        add(menu, "Rebuild Out-of-Date Wraps",
            #selector(BuilderAppDelegate.refreshStaleRuntimes(_:)), target: target)
        menu.addItem(.separator())
        add(menu, "Close Window", #selector(NSWindow.performClose(_:)), "w")
        item.submenu = menu
        return item
    }

    /// Without this menu, the boost editor's CSS and JavaScript fields have no ⌘C/⌘V —
    /// AppKit routes those through menu key equivalents, not through the text view.
    private static func editMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        add(menu, "Undo", Selector(("undo:")), "z")
        let redo = add(menu, "Redo", Selector(("redo:")), "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        add(menu, "Cut", Selector(("cut:")), "x")
        add(menu, "Copy", Selector(("copy:")), "c")
        add(menu, "Paste", Selector(("paste:")), "v")
        add(menu, "Delete", Selector(("delete:")))
        add(menu, "Select All", Selector(("selectAll:")), "a")
        item.submenu = menu
        return item
    }

    private static func windowMenu() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        add(menu, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, "Zoom", #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)))
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenu(target: BuilderAppDelegate) -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        add(menu, "Wrapybara Help", #selector(BuilderAppDelegate.showHelp(_:)), "?", target: target)
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?,
                            _ keyEquivalent: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = target
        menu.addItem(item)
        return item
    }
}

import AppKit

/// The app's main menu. A menu bar app with no main menu never routes ⌘C, ⌘V, ⌘A, ⌘Z or ⌘W to its
/// own windows, so search, Settings and the practice field would ignore them. The menu is not visible
/// while Saylark is menu bar only, and shows in the menu bar while the Saylark window is open; its
/// key equivalents work whenever one of Saylark's windows is in front.
@MainActor public enum AppMenu {
    public static func make(target: AnyObject, openMain: Selector, openSettings: Selector, find: Selector? = nil) -> NSMenu {
        let main = NSMenu()

        // Saylark
        let app = NSMenu(title: "Saylark")
        app.addItem(NSMenuItem(title: "About Saylark", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: openSettings, keyEquivalent: ",")
        settings.target = target
        app.addItem(settings)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide Saylark", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let others = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        others.keyEquivalentModifierMask = [.command, .option]
        app.addItem(others)
        app.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Quit Saylark", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        main.addItem(submenu(app))

        // Edit: the standard responder-chain actions, so text fields do their own work.
        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        if let find {
            // Puts the cursor in the search field of Home or Dictionary.
            edit.addItem(.separator())
            let item = NSMenuItem(title: "Find…", action: find, keyEquivalent: "f")
            item.target = target
            edit.addItem(item)
        }
        main.addItem(submenu(edit))

        // Window
        let window = NSMenu(title: "Window")
        let saylark = NSMenuItem(title: "Saylark", action: openMain, keyEquivalent: "0")
        saylark.target = target
        window.addItem(saylark)
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        main.addItem(submenu(window))
        return main
    }

    /// Installs the menu as the application's main menu and Window menu.
    public static func install(target: AnyObject, openMain: Selector, openSettings: Selector, find: Selector? = nil) {
        let menu = make(target: target, openMain: openMain, openSettings: openSettings, find: find)
        NSApp.mainMenu = menu
        NSApp.windowsMenu = menu.items.last?.submenu
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }
}

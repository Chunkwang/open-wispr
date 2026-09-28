import AppKit

/// A minimal main menu that exists only so the standard editing shortcuts work.
///
/// The app runs as an `.accessory` (menu bar) app and has no main menu. Without
/// one, Command-V, Command-C, Command-A, Command-Z and Command-W do nothing in a
/// text field, and pasting the sign-in code is the main way in. An accessory app
/// never shows its menu bar, so this menu is never seen: it only supplies the key
/// equivalents (docs/design/sign-in.md, 1.2). Every action goes to the first
/// responder (target nil), so it reaches whichever field has focus.
enum SignInMainMenu {
    /// The menu, built fresh. Separate from `installIfNeeded` so it can be
    /// inspected without an application.
    static func makeMenu() -> NSMenu {
        let main = NSMenu(title: "Main")

        // A main menu needs an application item first, even an empty one.
        let appItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        appItem.submenu = NSMenu(title: "")
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(item("Undo", Selector(("undo:")), "z"))
        edit.addItem(item("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(item("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(item("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(item("Select All", #selector(NSText.selectAll(_:)), "a"))
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(item("Close", #selector(NSWindow.performClose(_:)), "w"))
        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }

    private static func item(_ title: String, _ action: Selector, _ key: String, _ modifiers: NSEvent.ModifierFlags = [.command]) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }

    /// Installs the menu once, before the first window shows. An app that already
    /// has a main menu keeps it.
    @MainActor
    static func installIfNeeded() {
        guard NSApp.mainMenu == nil else { return }
        NSApp.mainMenu = makeMenu()
    }
}

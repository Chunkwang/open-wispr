import AppKit
import XCTest
@testable import OpenWisprLib

/// The minimal main menu that makes the editing shortcuts work in the accessory
/// app. Whether it does in the running app is a manual check; this pins its shape.
final class SignInMainMenuTests: XCTestCase {
    private func allItems(_ menu: NSMenu) -> [NSMenuItem] {
        menu.items.flatMap { item -> [NSMenuItem] in [item] + (item.submenu.map(allItems) ?? []) }
    }

    private func item(_ title: String) throws -> NSMenuItem {
        try XCTUnwrap(allItems(SignInMainMenu.makeMenu()).first { $0.title == title && $0.action != nil }, title)
    }

    func testAMainMenuNeedsAnApplicationItemFirst() {
        let menu = SignInMainMenu.makeMenu()
        XCTAssertEqual(menu.items.count, 3)
        XCTAssertNotNil(menu.items[0].submenu)
        XCTAssertEqual(menu.items[1].title, "Edit")
        XCTAssertEqual(menu.items[2].title, "Window")
    }

    func testEditingShortcutsGoToTheFirstResponder() throws {
        let expected: [(String, String, NSEvent.ModifierFlags, Selector)] = [
            ("Undo", "z", [.command], Selector(("undo:"))),
            ("Redo", "z", [.command, .shift], Selector(("redo:"))),
            ("Cut", "x", [.command], #selector(NSText.cut(_:))),
            ("Copy", "c", [.command], #selector(NSText.copy(_:))),
            ("Paste", "v", [.command], #selector(NSText.paste(_:))),
            ("Select All", "a", [.command], #selector(NSText.selectAll(_:))),
            ("Close", "w", [.command], #selector(NSWindow.performClose(_:))),
        ]
        for (title, key, modifiers, action) in expected {
            let found = try item(title)
            XCTAssertEqual(found.keyEquivalent, key, title)
            XCTAssertEqual(found.keyEquivalentModifierMask, modifiers, title)
            XCTAssertEqual(found.action, action, title)
            XCTAssertNil(found.target, "\(title) targets the first responder")
        }
    }

    func testTheMenuIsFreshEachTime() {
        XCTAssertFalse(SignInMainMenu.makeMenu() === SignInMainMenu.makeMenu())
    }
}

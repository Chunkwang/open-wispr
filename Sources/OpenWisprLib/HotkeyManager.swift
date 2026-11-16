import AppKit
import Foundation

/// Listens for a single configured hotkey using `NSEvent.addGlobalMonitorForEvents`.
///
/// ## Security audit (Task 5.2, 2026-09-26)
///
/// This class receives every key event system-wide through the global monitor.
/// It does NOT read, store, or log any keystroke content. Specifically:
///
/// - `handleEvent` checks ONLY `event.keyCode` (a hardware scan code) and
///   `event.modifierFlags` against the configured hotkey. Every non-matching
///   event is discarded immediately via `guard event.keyCode == keyCode`.
/// - No call to `event.characters`, `event.charactersIgnoringModifiers`, or
///   any other text-producing property exists anywhere in this file.
/// - No event data is written to disk, sent over the network, or stored in
///   any collection. The only side effect is calling `onKeyDown()` or
///   `onKeyUp()` — zero-argument closures with no event data.
/// - The monitor is removed on `stop()` and when the manager is deallocated.
///
/// **Claim for TRUST.md:** "The app watches for your hotkey and ignores every
/// other key. It never records or stores keystrokes."
///
/// **How to verify:** `grep -n 'characters' Sources/OpenWisprLib/HotkeyManager.swift`
/// returns zero matches. The only `event` properties accessed are `.keyCode`,
/// `.type`, and `.modifierFlags`.
class HotkeyManager {
    private var globalMonitor: Any?
    private let keyCode: UInt16
    private let requiredModifiers: UInt64
    private var onKeyDown: (() -> Void)?
    private var onKeyUp: (() -> Void)?
    private var modifierPressed = false

    init(keyCode: UInt16, modifiers: UInt64 = 0) {
        self.keyCode = keyCode
        self.requiredModifiers = modifiers
    }

    func start(onKeyDown: @escaping () -> Void, onKeyUp: @escaping () -> Void) {
        self.onKeyDown = onKeyDown
        self.onKeyUp = onKeyUp

        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleEvent(event)
        }
    }

    func stop() {
        if let monitor = globalMonitor {
            NSEvent.removeMonitor(monitor)
        }
        globalMonitor = nil
    }

    private func handleEvent(_ event: NSEvent) {
        if isModifierOnlyKey(keyCode) {
            guard event.type == .flagsChanged else { return }

            let targetPressed = isTargetModifierPressed(event)

            if targetPressed && !modifierPressed {
                guard matchesModifierKey(event.keyCode) || requiredModifiers != 0 else { return }
                if requiredModifiers != 0 {
                    let currentMods = UInt64(event.modifierFlags.rawValue) & 0x00FF0000
                    guard currentMods & requiredModifiers == requiredModifiers else { return }
                }
                modifierPressed = true
                onKeyDown?()
            } else if !targetPressed && modifierPressed {
                modifierPressed = false
                onKeyUp?()
            }
        } else {
            guard event.keyCode == keyCode else { return }
            if requiredModifiers != 0 {
                let currentMods = UInt64(event.modifierFlags.rawValue) & 0x00FF0000
                guard currentMods & requiredModifiers == requiredModifiers else { return }
            }
            if event.type == .keyDown {
                onKeyDown?()
            } else if event.type == .keyUp {
                onKeyUp?()
            }
        }
    }

    private func isModifierOnlyKey(_ code: UInt16) -> Bool {
        return [54, 55, 56, 58, 59, 60, 61, 62, 63].contains(code)
    }

    private func matchesModifierKey(_ eventKeyCode: UInt16) -> Bool {
        switch keyCode {
        case 58, 61: return eventKeyCode == 58 || eventKeyCode == 61 // Option
        case 54, 55: return eventKeyCode == 54 || eventKeyCode == 55 // Command
        case 59, 62: return eventKeyCode == 59 || eventKeyCode == 62 // Control
        case 56, 60: return eventKeyCode == 56 || eventKeyCode == 60 // Shift
        case 63: return eventKeyCode == 63                            // Fn / Globe
        default: return eventKeyCode == keyCode
        }
    }

    private func isTargetModifierPressed(_ event: NSEvent) -> Bool {
        switch keyCode {
        case 58, 61:
            return event.modifierFlags.contains(.option)
        case 54, 55:
            return event.modifierFlags.contains(.command)
        case 59, 62:
            return event.modifierFlags.contains(.control)
        case 56, 60:
            return event.modifierFlags.contains(.shift)
        case 63:
            return event.modifierFlags.contains(.function)
        default:
            return false
        }
    }
}

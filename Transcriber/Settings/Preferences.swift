//
//  Preferences.swift
//  Transcriber
//

import Foundation
import Carbon.HIToolbox

/// UserDefaults-backed app preferences.
final class Preferences {
    static let shared = Preferences()

    private let defaults: UserDefaults

    private enum Key {
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hotkeyKeyCode: Int(HotkeyManager.Shortcut.default.keyCode),
            Key.hotkeyModifiers: Int(HotkeyManager.Shortcut.default.carbonModifiers),
        ])
    }

    var hotkeyShortcut: HotkeyManager.Shortcut {
        get {
            HotkeyManager.Shortcut(keyCode: UInt32(defaults.integer(forKey: Key.hotkeyKeyCode)),
                                   carbonModifiers: UInt32(defaults.integer(forKey: Key.hotkeyModifiers)))
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Key.hotkeyKeyCode)
            defaults.set(Int(newValue.carbonModifiers), forKey: Key.hotkeyModifiers)
        }
    }
}

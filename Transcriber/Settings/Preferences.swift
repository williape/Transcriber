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
        static let insertionMode = "insertionMode"
        static let accessibilityPromptShown = "accessibilityPromptShown"
        static let playsSounds = "playsSounds"
        static let localeIdentifier = "localeIdentifier"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hotkeyKeyCode: Int(HotkeyManager.Shortcut.default.keyCode),
            Key.hotkeyModifiers: Int(HotkeyManager.Shortcut.default.carbonModifiers),
            Key.insertionMode: OutputRouter.InsertionMode.paste.rawValue,
            Key.playsSounds: true,
        ])
    }

    var playsSounds: Bool {
        get { defaults.bool(forKey: Key.playsSounds) }
        set { defaults.set(newValue, forKey: Key.playsSounds) }
    }

    /// Transcription locale; empty identifier means "follow the system".
    var selectedLocale: Locale {
        get {
            let identifier = defaults.string(forKey: Key.localeIdentifier) ?? ""
            return identifier.isEmpty ? .current : Locale(identifier: identifier)
        }
        set {
            defaults.set(newValue.identifier(.bcp47), forKey: Key.localeIdentifier)
        }
    }

    var insertionMode: OutputRouter.InsertionMode {
        get {
            OutputRouter.InsertionMode(rawValue: defaults.string(forKey: Key.insertionMode) ?? "") ?? .paste
        }
        set {
            defaults.set(newValue.rawValue, forKey: Key.insertionMode)
        }
    }

    var accessibilityPromptShown: Bool {
        get { defaults.bool(forKey: Key.accessibilityPromptShown) }
        set { defaults.set(newValue, forKey: Key.accessibilityPromptShown) }
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

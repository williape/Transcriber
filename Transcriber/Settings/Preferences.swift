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
        static let keepsTranscriptHistory = "keepsTranscriptHistory"
        static let keepsAudioRecordings = "keepsAudioRecordings"
        static let historyRetentionDays = "historyRetentionDays"
        static let audioStorageCapBytes = "audioStorageCapBytes"
        static let panelOriginX = "panelOriginX"
        static let panelOriginY = "panelOriginY"
    }

    /// Byte caps offered in Settings. 0 means "no limit".
    enum AudioCap {
        static let noLimit = 0
        static let oneGigabyte = 1_073_741_824
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.hotkeyKeyCode: Int(HotkeyManager.Shortcut.default.keyCode),
            Key.hotkeyModifiers: Int(HotkeyManager.Shortcut.default.carbonModifiers),
            Key.insertionMode: OutputRouter.InsertionMode.paste.rawValue,
            Key.playsSounds: true,
            Key.keepsTranscriptHistory: true,
            // Audio is the sensitive, bulky part: opt-in, and capped by default
            // once it is on.
            Key.keepsAudioRecordings: false,
            Key.historyRetentionDays: 0,
            Key.audioStorageCapBytes: AudioCap.oneGigabyte,
        ])
    }

    /// Where the user last dragged the dictation panel, in screen coordinates.
    /// `nil` until it has been moved, which means "use the default position".
    var panelOrigin: NSPoint? {
        get {
            guard defaults.object(forKey: Key.panelOriginX) != nil,
                  defaults.object(forKey: Key.panelOriginY) != nil else { return nil }
            return NSPoint(x: defaults.double(forKey: Key.panelOriginX),
                           y: defaults.double(forKey: Key.panelOriginY))
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.panelOriginX)
                defaults.removeObject(forKey: Key.panelOriginY)
                return
            }
            defaults.set(Double(newValue.x), forKey: Key.panelOriginX)
            defaults.set(Double(newValue.y), forKey: Key.panelOriginY)
        }
    }

    /// Whether each dictation's audio is written alongside its transcript.
    var keepsAudioRecordings: Bool {
        get { defaults.bool(forKey: Key.keepsAudioRecordings) }
        set { defaults.set(newValue, forKey: Key.keepsAudioRecordings) }
    }

    /// Entries older than this are deleted automatically. 0 = never.
    var historyRetentionDays: Int {
        get { defaults.integer(forKey: Key.historyRetentionDays) }
        set { defaults.set(newValue, forKey: Key.historyRetentionDays) }
    }

    /// Ceiling on total retained audio; oldest audio is reclaimed first and the
    /// transcripts are kept. 0 = no limit.
    var audioStorageCapBytes: Int {
        get { defaults.integer(forKey: Key.audioStorageCapBytes) }
        set { defaults.set(newValue, forKey: Key.audioStorageCapBytes) }
    }

    /// Whether finished dictations are archived to the history store.
    var keepsTranscriptHistory: Bool {
        get { defaults.bool(forKey: Key.keepsTranscriptHistory) }
        set { defaults.set(newValue, forKey: Key.keepsTranscriptHistory) }
    }

    /// Suppresses history for the current app run only — deliberately *not*
    /// persisted, because a pause is for right now, not forever.
    var historyPaused = false

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

    /// Whether the system Accessibility prompt has been shown *since the app was
    /// last known to be trusted* — not "ever". `OutputRouter` clears it every
    /// time it observes a live grant, so a grant that later stops applying earns
    /// the user one fresh prompt instead of permanent silence.
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

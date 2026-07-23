//
//  HotkeyManager.swift
//  Transcriber
//

import AppKit
import Carbon.HIToolbox
import os

/// Global hotkey via Carbon `RegisterEventHotKey`: needs no TCC permission and
/// consumes the keystroke, unlike `NSEvent.addGlobalMonitorForEvents`.
final class HotkeyManager {
    struct Shortcut: Equatable {
        var keyCode: UInt32
        var carbonModifiers: UInt32

        static let `default` = Shortcut(keyCode: UInt32(kVK_Space),
                                        carbonModifiers: UInt32(optionKey))

        var displayString: String {
            var parts = ""
            if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
            if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
            if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
            if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
            return parts + Self.keyName(for: keyCode)
        }

        private static func keyName(for keyCode: UInt32) -> String {
            switch Int(keyCode) {
            case kVK_Space: return "Space"
            case kVK_Return: return "Return"
            case kVK_Escape: return "Esc"
            default: return "key \(keyCode)"
            }
        }
    }

    /// Invoked on the main queue when the hotkey fires.
    var onHotkey: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Hotkey")

    private static let signature: OSType = {
        "TRSC".utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    @discardableResult
    func register(_ shortcut: Shortcut) -> Bool {
        unregister()
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         shortcut.carbonModifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &hotKeyRef)
        guard status == noErr, hotKeyRef != nil else {
            logger.error("RegisterEventHotKey failed (status \(status)) for \(shortcut.displayString, privacy: .public)")
            hotKeyRef = nil
            return false
        }
        logger.info("Registered hotkey \(shortcut.displayString, privacy: .public)")
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { manager.onHotkey?() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
    }

    deinit {
        unregister()
        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }
    }
}

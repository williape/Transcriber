//
//  HotkeyManager.swift
//  Transcriber
//

import AppKit
import Carbon.HIToolbox
import os

/// Global hotkeys via Carbon `RegisterEventHotKey`: needs no TCC permission and
/// consumes the keystroke, unlike `NSEvent.addGlobalMonitorForEvents`.
/// Supports multiple concurrent registrations (main shortcut, transient Esc).
/// App-lifetime object; registrations are released explicitly, not in deinit.
@MainActor
final class HotkeyManager {
    struct Shortcut: Equatable {
        var keyCode: UInt32
        var carbonModifiers: UInt32

        static let `default` = Shortcut(keyCode: UInt32(kVK_Space),
                                        carbonModifiers: UInt32(optionKey))
        static let escape = Shortcut(keyCode: UInt32(kVK_Escape), carbonModifiers: 0)

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

    typealias HotkeyID = UInt32

    private var handlers: [HotkeyID: @MainActor () -> Void] = [:]
    private var hotKeyRefs: [HotkeyID: EventHotKeyRef] = [:]
    private var nextID: HotkeyID = 1
    private var eventHandlerRef: EventHandlerRef?
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Hotkey")

    private static let signature: OSType = {
        "TRSC".utf8.reduce(0) { ($0 << 8) | OSType($1) }
    }()

    /// Returns nil if registration fails (e.g. shortcut taken by another app).
    func register(_ shortcut: Shortcut, handler: @escaping @MainActor () -> Void) -> HotkeyID? {
        installEventHandlerIfNeeded()

        let id = nextID
        nextID += 1
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var hotKeyRef: EventHotKeyRef?
        let status = RegisterEventHotKey(shortcut.keyCode,
                                         shortcut.carbonModifiers,
                                         hotKeyID,
                                         GetEventDispatcherTarget(),
                                         0,
                                         &hotKeyRef)
        guard status == noErr, let hotKeyRef else {
            logger.error("RegisterEventHotKey failed (status \(status)) for \(shortcut.displayString, privacy: .public)")
            return nil
        }
        hotKeyRefs[id] = hotKeyRef
        handlers[id] = handler
        logger.info("Registered hotkey \(shortcut.displayString, privacy: .public) (id \(id))")
        return id
    }

    func unregister(_ id: HotkeyID) {
        if let ref = hotKeyRefs.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
        handlers.removeValue(forKey: id)
    }

    private func dispatch(_ id: HotkeyID) {
        handlers[id]?()
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, userData in
            guard let userData, let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hotKeyID)
            guard hotKeyID.signature == HotkeyManager.signature else { return noErr }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            let id = hotKeyID.id
            Task { @MainActor in
                manager.dispatch(id)
            }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)
    }
}

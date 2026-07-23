//
//  HotkeyManager.swift
//  Transcriber
//

import AppKit
import Carbon
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

        /// Global shortcuts must include ⌘, ⌥, or ⌃ so ordinary typing can't
        /// trigger them — except function keys, which are safe bare.
        var isValidGlobalShortcut: Bool {
            if Self.functionKeyCodes.contains(Int(keyCode)) { return true }
            return carbonModifiers & UInt32(cmdKey | optionKey | controlKey) != 0
        }

        private static let functionKeyCodes: Set<Int> = [
            kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
            kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20,
        ]

        private static let namedKeys: [Int: String] = [
            kVK_Space: "Space", kVK_Return: "Return", kVK_ANSI_KeypadEnter: "Enter",
            kVK_Escape: "Esc", kVK_Tab: "Tab", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "Home", kVK_End: "End", kVK_PageUp: "Page Up", kVK_PageDown: "Page Down",
            kVK_Help: "Help",
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
            kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
            kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15",
            kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
        ]

        private static func keyName(for keyCode: UInt32) -> String {
            if let name = namedKeys[Int(keyCode)] { return name }
            if let character = layoutCharacter(for: keyCode) { return character }
            return "key \(keyCode)"
        }

        /// Character the key produces in the current keyboard layout (no modifiers).
        private static func layoutCharacter(for keyCode: UInt32) -> String? {
            guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
                  let rawLayoutData = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
                return nil
            }
            let layoutData = Unmanaged<CFData>.fromOpaque(rawLayoutData).takeUnretainedValue() as Data
            return layoutData.withUnsafeBytes { buffer -> String? in
                guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                    return nil
                }
                var deadKeyState: UInt32 = 0
                var characters = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout,
                                            UInt16(keyCode),
                                            UInt16(kUCKeyActionDisplay),
                                            0,
                                            UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                            &deadKeyState,
                                            characters.count,
                                            &length,
                                            &characters)
                guard status == noErr, length > 0 else { return nil }
                let string = String(utf16CodeUnits: characters, count: length)
                guard !string.isEmpty, string.rangeOfCharacter(from: .controlCharacters) == nil else {
                    return nil
                }
                return string.uppercased()
            }
        }
    }

    typealias HotkeyID = UInt32

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        return modifiers
    }

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

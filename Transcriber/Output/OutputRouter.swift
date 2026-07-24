//
//  OutputRouter.swift
//  Transcriber
//

import AppKit
import ApplicationServices
import Carbon.HIToolbox
import os

/// Routes a finished transcript to the user's active app: synthetic ⌘V paste
/// (with pasteboard save/restore) when permitted, clipboard otherwise.
@MainActor
final class OutputRouter {
    enum InsertionMode: String {
        case paste          // direct insertion via ⌘V when Accessibility granted
        case clipboardOnly
    }

    enum Outcome {
        case inserted
        case copiedToClipboard
    }

    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Output")

    func deliver(_ text: String, mode: InsertionMode) async -> Outcome {
        switch mode {
        case .clipboardOnly:
            copyToClipboard(text)
            logger.info("Copied \(text.count) characters to clipboard (clipboard-only mode)")
            return .copiedToClipboard
        case .paste:
            guard ensureAccessibilityTrust() else {
                copyToClipboard(text)
                logger.info("Accessibility not granted; left text on clipboard")
                return .copiedToClipboard
            }
            // Password fields block synthetic paste — don't even try.
            guard !IsSecureEventInputEnabled() else {
                copyToClipboard(text)
                logger.info("Secure input active; left text on clipboard")
                return .copiedToClipboard
            }
            return await pasteIntoActiveApp(text)
        }
    }

    /// Shows the system Accessibility onboarding dialog on the first refusal;
    /// afterwards falls back silently (Settings has a shortcut button too).
    private func ensureAccessibilityTrust() -> Bool {
        if AXIsProcessTrusted() {
            return true
        }
        if !Preferences.shared.accessibilityPromptShown {
            Preferences.shared.accessibilityPromptShown = true
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        return false
    }

    private func pasteIntoActiveApp(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ownedChangeCount = pasteboard.changeCount

        // Let the pasteboard settle, paste, then give the target app time to
        // consume ⌘V before restoring the previous contents.
        try? await Task.sleep(for: .milliseconds(50))
        postCommandV()
        try? await Task.sleep(for: .milliseconds(400))

        // Only restore if our transcript is still the clipboard's contents —
        // if the user copied something during the delay, that's newer than the
        // snapshot and must not be clobbered.
        guard pasteboard.changeCount == ownedChangeCount else {
            logger.info("Inserted \(text.count) characters via ⌘V; clipboard changed meanwhile, not restored")
            return .inserted
        }
        restore(saved, to: pasteboard)

        logger.info("Inserted \(text.count) characters via ⌘V; clipboard restored")
        return .inserted
    }

    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    private func snapshot(of pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var contents = [NSPasteboard.PasteboardType: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    contents[type] = data
                }
            }
            return contents
        }
    }

    private func restore(_ saved: [[NSPasteboard.PasteboardType: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        let items = saved.map { contents -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in contents {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(items)
    }
}

//
//  ShortcutRecorderView.swift
//  Transcriber
//

import AppKit
import Carbon.HIToolbox
import SwiftUI

/// AppDelegate-provided hooks for changing the global dictation hotkey.
/// `begin` unregisters the current hotkey so it can't fire (or be blocked from
/// capture) while recording; `commit` registers + persists the new shortcut,
/// restoring the old one and returning false if registration fails; `cancel`
/// restores the old registration after an abandoned recording.
@MainActor
struct ShortcutRebinder {
    let begin: () -> Void
    let commit: (HotkeyManager.Shortcut) -> Bool
    let cancel: () -> Void

    static let noop = ShortcutRebinder(begin: {}, commit: { _ in true }, cancel: {})
}

/// Click-to-record shortcut field: captures the next key combination via a
/// local event monitor (the settings window is key, so local is enough).
struct ShortcutRecorderView: View {
    let rebinder: ShortcutRebinder

    @State private var shortcut = Preferences.shared.hotkeyShortcut
    @State private var isRecording = false
    @State private var message: String?
    @State private var monitor: Any?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Button(action: toggleRecording) {
                    Text(isRecording ? "Type shortcut…" : shortcut.displayString)
                        .frame(minWidth: 100)
                }
                if !isRecording && shortcut != .default {
                    Button("Reset to \(HotkeyManager.Shortcut.default.displayString)") {
                        apply(.default)
                    }
                    .buttonStyle(.link)
                    .font(.footnote)
                }
            }
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear {
            cancelRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            // Clicking away mid-recording must not leave the hotkey unregistered.
            cancelRecording()
        }
    }

    private func toggleRecording() {
        isRecording ? cancelRecording() : startRecording()
    }

    private func startRecording() {
        rebinder.begin()
        isRecording = true
        message = "Press the new key combination. Esc cancels."
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                handle(event)
            }
            return nil // consume while recording
        }
    }

    private func handle(_ event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if Int(event.keyCode) == kVK_Escape, flags.isEmpty {
            cancelRecording()
            return
        }
        let candidate = HotkeyManager.Shortcut(keyCode: UInt32(event.keyCode),
                                               carbonModifiers: HotkeyManager.carbonModifiers(from: flags))
        guard candidate.isValidGlobalShortcut else {
            message = "Include ⌘, ⌥, or ⌃ — or use a function key."
            return
        }
        stopMonitor()
        isRecording = false
        if rebinder.commit(candidate) {
            shortcut = candidate
            message = nil
        } else {
            message = "\(candidate.displayString) couldn't be registered — it may be in use by another app. Kept \(shortcut.displayString)."
        }
    }

    /// Set a shortcut directly (reset button), without a recording session.
    private func apply(_ candidate: HotkeyManager.Shortcut) {
        rebinder.begin()
        if rebinder.commit(candidate) {
            shortcut = candidate
            message = nil
        } else {
            message = "\(candidate.displayString) couldn't be registered — it may be in use by another app."
        }
    }

    private func cancelRecording() {
        guard isRecording else { return }
        stopMonitor()
        isRecording = false
        message = nil
        rebinder.cancel()
    }

    private func stopMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

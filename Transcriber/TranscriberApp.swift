//
//  TranscriberApp.swift
//  Transcriber
//

import AppKit
import os

@main
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // NSApplication.delegate is weak; keep the delegate alive for the process lifetime.
    private static var sharedDelegate: AppDelegate?

    static func main() {
        let delegate = AppDelegate()
        sharedDelegate = delegate
        let app = NSApplication.shared
        app.delegate = delegate
        app.run()
    }

    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "App")

    private var appState: AppState!
    private var statusItemController: StatusItemController!
    private var hotkeyManager: HotkeyManager!
    private var panelController: PanelController!
    private var settingsWindowController: SettingsWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        statusItemController = StatusItemController(appState: appState)
        hotkeyManager = HotkeyManager()
        panelController = PanelController(appState: appState, hotkeyManager: hotkeyManager)

        statusItemController.onToggleDictation = { [weak self] in
            self?.appState.toggleDictation()
        }
        statusItemController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }

        let shortcut = Preferences.shared.hotkeyShortcut
        if hotkeyManager.register(shortcut, handler: { [weak self] in
            self?.appState.toggleDictation()
        }) == nil {
            presentHotkeyRegistrationFailure(for: shortcut)
        }

        logger.info("Launched; hotkey \(shortcut.displayString, privacy: .public)")
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController()
        }
        settingsWindowController?.show()
    }

    private func presentHotkeyRegistrationFailure(for shortcut: HotkeyManager.Shortcut) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Global shortcut unavailable"
        alert.informativeText = """
        Transcriber could not register \(shortcut.displayString) — another app may already \
        be using it. Dictation still works from the menu bar icon.
        """
        alert.alertStyle = .warning
        alert.runModal()
    }
}

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
    private var engine: TranscriptionEngine!
    private var outputRouter: OutputRouter!
    private var settingsWindowController: SettingsWindowController?
    private var sessionTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        statusItemController = StatusItemController(appState: appState)
        hotkeyManager = HotkeyManager()
        panelController = PanelController(appState: appState, hotkeyManager: hotkeyManager)
        engine = TranscriptionEngine()
        outputRouter = OutputRouter()

        engine.onTranscript = { [weak self] committed, volatile in
            self?.appState.updateTranscript(committed: committed, volatile: volatile)
        }
        statusItemController.onToggleDictation = { [weak self] in
            self?.toggleDictation()
        }
        statusItemController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        panelController.onEscape = { [weak self] in
            self?.cancelDictation()
        }

        let shortcut = Preferences.shared.hotkeyShortcut
        if hotkeyManager.register(shortcut, handler: { [weak self] in
            self?.toggleDictation()
        }) == nil {
            presentHotkeyRegistrationFailure(for: shortcut)
        }

        logger.info("Launched; hotkey \(shortcut.displayString, privacy: .public)")
    }

    // MARK: - Dictation orchestration

    private func toggleDictation() {
        switch appState.session {
        case .idle where sessionTask == nil:
            startDictation()
        case .recording:
            stopDictation()
        default:
            break
        }
    }

    private func startDictation() {
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            appState.clearTranscript()
            do {
                let appState = self.appState!
                try await engine.startSession(locale: .current) { fraction in
                    Task { @MainActor in
                        appState.transition(to: .downloadingModel(progress: fraction))
                    }
                }
                appState.transition(to: .recording)
            } catch {
                appState.transition(to: .idle)
                presentError(error)
            }
        }
    }

    private func stopDictation() {
        appState.transition(to: .finishing)
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            do {
                let text = try await engine.finishSession()
                if !text.isEmpty {
                    appState.updateTranscript(committed: text, volatile: "")
                    appState.transition(to: .inserting)
                    let outcome = await outputRouter.deliver(text, mode: Preferences.shared.insertionMode)
                    logger.info("Delivery outcome: \(String(describing: outcome), privacy: .public)")
                }
            } catch {
                presentError(error)
            }
            appState.clearTranscript()
            appState.transition(to: .idle)
        }
    }

    private func cancelDictation() {
        guard appState.session == .recording else { return }
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            await engine.cancelSession()
            appState.clearTranscript()
            appState.transition(to: .idle)
        }
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

    private func presentError(_ error: Error) {
        logger.error("Session error: \(error.localizedDescription, privacy: .public)")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Dictation failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
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

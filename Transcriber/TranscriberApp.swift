//
//  TranscriberApp.swift
//  Transcriber
//

import AppKit
import UniformTypeIdentifiers
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
    private var fileTranscriber: FileTranscriber!
    private var settingsWindowController: SettingsWindowController?
    private var transcriptWindows: [TranscriptWindowController] = []
    private var sessionTask: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        statusItemController = StatusItemController(appState: appState)
        hotkeyManager = HotkeyManager()
        panelController = PanelController(appState: appState, hotkeyManager: hotkeyManager)
        engine = TranscriptionEngine()
        outputRouter = OutputRouter()
        fileTranscriber = FileTranscriber()

        engine.onTranscript = { [weak self] committed, volatile in
            self?.appState.updateTranscript(committed: committed, volatile: volatile)
        }
        engine.onLevel = { [weak self] level in
            self?.appState.updateAudioLevel(level)
        }
        statusItemController.onToggleDictation = { [weak self] in
            self?.toggleDictation()
        }
        statusItemController.onOpenSettings = { [weak self] in
            self?.openSettings()
        }
        statusItemController.onTranscribeFilePrompt = { [weak self] in
            self?.promptForFileToTranscribe()
        }
        statusItemController.onFileDropped = { [weak self] url in
            self?.transcribeFile(url)
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

    // MARK: - File transcription

    private func promptForFileToTranscribe() {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = false
        panel.message = "Choose an audio or video file to transcribe"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.transcribeFile(url)
        }
    }

    private func transcribeFile(_ url: URL) {
        guard appState.session == .idle, sessionTask == nil else {
            logger.info("File transcription request ignored while busy")
            return
        }
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            let appState = self.appState!
            appState.transition(to: .transcribingFile(progress: 0))
            do {
                let text = try await fileTranscriber.transcribe(
                    url: url,
                    locale: Preferences.shared.selectedLocale,
                    modelDownloadProgress: { fraction in
                        Task { @MainActor in
                            appState.transition(to: .downloadingModel(progress: fraction))
                        }
                    },
                    onProgress: { fraction in
                        Task { @MainActor in
                            appState.transition(to: .transcribingFile(progress: fraction))
                        }
                    })
                appState.transition(to: .idle)
                presentTranscript(text, for: url)
            } catch {
                appState.transition(to: .idle)
                presentError(error)
            }
        }
    }

    private func presentTranscript(_ text: String, for url: URL) {
        guard !text.isEmpty else {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "No speech detected"
            alert.informativeText = "Nothing to transcribe was found in \"\(url.lastPathComponent)\"."
            alert.runModal()
            return
        }
        let controller = TranscriptWindowController(text: text, sourceURL: url)
        transcriptWindows.append(controller)
        if let window = controller.window {
            weak let weakSelf = self
            weak let weakController = controller
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                                   object: window,
                                                   queue: .main) { _ in
                Task { @MainActor in
                    weakSelf?.transcriptWindows.removeAll { $0 === weakController }
                }
            }
        }
        controller.show()
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
                try await engine.startSession(locale: Preferences.shared.selectedLocale) { fraction in
                    Task { @MainActor in
                        appState.transition(to: .downloadingModel(progress: fraction))
                    }
                }
                appState.transition(to: .recording)
                SoundPlayer.playStart()
            } catch {
                appState.transition(to: .idle)
                presentError(error)
            }
        }
    }

    private func stopDictation() {
        appState.transition(to: .finishing)
        appState.updateAudioLevel(0)
        SoundPlayer.playStop()
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            do {
                let text = try await engine.finishSession()
                if !text.isEmpty {
                    appState.updateTranscript(committed: text, volatile: "")
                    appState.transition(to: .inserting)
                    let outcome = await outputRouter.deliver(text, mode: Preferences.shared.insertionMode)
                    logger.info("Delivery outcome: \(String(describing: outcome), privacy: .public)")
                } else {
                    // Hold the panel briefly so the user learns why nothing was inserted.
                    appState.showNotice("No speech detected")
                    try? await Task.sleep(for: .seconds(1.5))
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
            appState.updateAudioLevel(0)
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

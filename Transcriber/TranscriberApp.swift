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
    /// nil when the history store couldn't be opened at all — dictation still works.
    private var historyStore: HistoryStore?
    private var historyWindowController: HistoryWindowController?
    private var frontmostAppTracker: FrontmostAppTracker!
    private var settingsWindowController: SettingsWindowController?
    private var transcriptWindows: [TranscriptWindowController] = []
    private var sessionTask: Task<Void, Never>?
    private var mainHotkeyID: HotkeyManager.HotkeyID?
    /// The app that was frontmost when recording started — which, because the
    /// panel never activates, is still the insertion target when it ends.
    private var sessionTargetApp: (bundleID: String?, name: String?)?
    /// Bumped for every dictation/file operation so progress ticks that arrive
    /// late (see `progressSink`) can tell they belong to a finished operation.
    private var operationGeneration = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        statusItemController = StatusItemController(appState: appState)
        hotkeyManager = HotkeyManager()
        panelController = PanelController(appState: appState, hotkeyManager: hotkeyManager)
        engine = TranscriptionEngine()
        outputRouter = OutputRouter()
        fileTranscriber = FileTranscriber()
        frontmostAppTracker = FrontmostAppTracker()
        openHistoryStore()

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
        statusItemController.onOpenHistory = { [weak self] in
            self?.openHistory()
        }
        statusItemController.recentTranscripts = { [weak self] in
            self?.recentTranscripts() ?? []
        }
        statusItemController.onInsertTranscript = { [weak self] text in
            self?.reinsert(text)
        }
        statusItemController.onCopyLastTranscript = { [weak self] in
            self?.copyLastTranscript()
        }
        panelController.onEscape = { [weak self] in
            self?.cancelDictation()
        }

        let shortcut = Preferences.shared.hotkeyShortcut
        if !registerMainHotkey(shortcut) {
            presentHotkeyRegistrationFailure(for: shortcut)
        }

        logger.info("Launched; hotkey \(shortcut.displayString, privacy: .public)")
    }

    // MARK: - History

    private func openHistoryStore() {
        do {
            let store = try HistoryStore()
            historyStore = store
            logger.info("History: \(store.entryCount()) entries")
        } catch {
            // History is a convenience; dictation must not depend on it.
            logger.error("History unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func openHistory() {
        guard let historyStore else {
            presentHistoryUnavailable()
            return
        }
        if historyWindowController == nil {
            let actions = HistoryActions(insert: { [weak self] text in
                await self?.reinsertAndReport(text) ?? .copiedToClipboard
            })
            historyWindowController = HistoryWindowController(container: historyStore.container,
                                                              actions: actions)
        }
        historyWindowController?.show()
    }

    /// Newest entries for the menu bar submenu, as plain values — `@Model`
    /// objects shouldn't be handed to AppKit menu items that outlive the fetch.
    private func recentTranscripts(limit: Int = 5) -> [RecentTranscript] {
        guard let historyStore else { return [] }
        return historyStore.recent(limit: limit).map { entry in
            RecentTranscript(title: HistoryFormat.snippet(entry.text, limit: 48),
                             text: entry.text)
        }
    }

    private func reinsert(_ text: String) {
        Task { @MainActor in
            _ = await reinsertAndReport(text)
        }
    }

    @discardableResult
    private func reinsertAndReport(_ text: String) async -> OutputRouter.Outcome {
        let outcome = await outputRouter.reinsert(text,
                                                 mode: Preferences.shared.insertionMode,
                                                 into: frontmostAppTracker.lastExternalApp)
        logger.info("Re-insert outcome: \(String(describing: outcome), privacy: .public)")
        return outcome
    }

    private func copyLastTranscript() {
        guard let text = recentTranscripts(limit: 1).first?.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        logger.info("Copied last transcript (\(text.count) characters)")
    }

    private func presentHistoryUnavailable() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "History unavailable"
        alert.informativeText = "Transcriber couldn't open its history store, so past dictations can't be shown. Dictation itself is unaffected."
        alert.alertStyle = .warning
        alert.runModal()
    }

    // MARK: - Main hotkey (re)registration

    @discardableResult
    private func registerMainHotkey(_ shortcut: HotkeyManager.Shortcut) -> Bool {
        mainHotkeyID = hotkeyManager.register(shortcut) { [weak self] in
            self?.toggleDictation()
        }
        return mainHotkeyID != nil
    }

    private func unregisterMainHotkey() {
        if let mainHotkeyID {
            hotkeyManager.unregister(mainHotkeyID)
            self.mainHotkeyID = nil
        }
    }

    /// Hooks handed to the Settings shortcut recorder. `begin` frees the
    /// current hotkey so recording can capture it; `commit` swaps in the new
    /// one (restoring the old on failure); `cancel` restores after abandonment.
    private func makeShortcutRebinder() -> ShortcutRebinder {
        ShortcutRebinder(
            begin: { [weak self] in
                self?.unregisterMainHotkey()
            },
            commit: { [weak self] shortcut in
                guard let self else { return false }
                if registerMainHotkey(shortcut) {
                    Preferences.shared.hotkeyShortcut = shortcut
                    logger.info("Hotkey changed to \(shortcut.displayString, privacy: .public)")
                    return true
                }
                registerMainHotkey(Preferences.shared.hotkeyShortcut)
                return false
            },
            cancel: { [weak self] in
                guard let self, mainHotkeyID == nil else { return }
                registerMainHotkey(Preferences.shared.hotkeyShortcut)
            })
    }

    // MARK: - Progress plumbing

    private enum ProgressKind {
        case modelDownload
        case fileTranscription
    }

    /// Progress callbacks fire from the download poller and the file results
    /// loop, and reach the main actor through an unstructured task — so a tick
    /// can land *after* the operation already transitioned to `.recording` or
    /// `.idle` and strand the UI in a stale progress state. Stamping each tick
    /// with the generation it was created for makes late ones no-ops.
    private func progressSink(_ kind: ProgressKind, generation: Int) -> @Sendable (Double) -> Void {
        { [weak self] fraction in
            guard let self else { return }
            Task { @MainActor in
                guard self.operationGeneration == generation else { return }
                switch kind {
                case .modelDownload:
                    self.appState.transition(to: .downloadingModel(progress: fraction))
                case .fileTranscription:
                    self.appState.transition(to: .transcribingFile(progress: fraction))
                }
            }
        }
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
        operationGeneration += 1
        let generation = operationGeneration
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            appState.transition(to: .transcribingFile(progress: 0))
            do {
                let text = try await fileTranscriber.transcribe(
                    url: url,
                    locale: Preferences.shared.selectedLocale,
                    modelDownloadProgress: progressSink(.modelDownload, generation: generation),
                    onProgress: progressSink(.fileTranscription, generation: generation))
                operationGeneration += 1
                appState.transition(to: .idle)
                presentTranscript(text, for: url)
            } catch {
                operationGeneration += 1
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
        // `sessionTask != nil` means an async start/stop/cancel is still in
        // flight; the session state alone can't be trusted to gate re-entry.
        guard sessionTask == nil else { return }
        switch appState.session {
        case .idle:
            startDictation()
        case .recording:
            stopDictation()
        default:
            break
        }
    }

    private func startDictation() {
        operationGeneration += 1
        let generation = operationGeneration
        // The last app that wasn't us — right whether the user was in another
        // app or had our own Settings window open.
        let target = frontmostAppTracker.lastExternalApp
        sessionTargetApp = (target?.bundleIdentifier, target?.localizedName)
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            appState.clearTranscript()
            do {
                try await engine.startSession(
                    locale: Preferences.shared.selectedLocale,
                    modelDownloadProgress: progressSink(.modelDownload, generation: generation))
                operationGeneration += 1
                appState.transition(to: .recording)
                SoundPlayer.playStart()
            } catch {
                operationGeneration += 1
                appState.transition(to: .idle)
                presentError(error)
            }
        }
    }

    private func stopDictation() {
        guard appState.session == .recording, sessionTask == nil else { return }
        // Leave `.recording` synchronously so a second hotkey press can't
        // start an overlapping finish.
        appState.transition(to: .finishing)
        appState.updateAudioLevel(0)
        SoundPlayer.playStop()
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            do {
                let result = try await engine.finishSession()
                await deliver(result)
            } catch TranscriptionEngine.EngineError.transcriptionIncomplete(let partial, let underlying)
                        where !partial.text.isEmpty {
                // The stream died mid-session but the words we did get are
                // still the user's — insert them rather than throwing them away.
                logger.error("Transcript truncated: \(underlying.localizedDescription, privacy: .public)")
                await deliver(partial.markedPartial())
            } catch {
                presentError(error)
            }
            appState.clearTranscript()
            appState.transition(to: .idle)
        }
    }

    private func deliver(_ result: SessionResult) async {
        guard !result.text.isEmpty else {
            // Hold the panel briefly so the user learns why nothing was inserted.
            // Nothing was said, so nothing is worth archiving either.
            appState.showNotice("No speech detected")
            try? await Task.sleep(for: .seconds(1.5))
            return
        }
        appState.updateTranscript(committed: result.text, volatile: "")
        appState.transition(to: .inserting)
        let outcome = await outputRouter.deliver(result.text, mode: Preferences.shared.insertionMode)
        logger.info("Delivery outcome: \(String(describing: outcome), privacy: .public)")
        // After delivery, so the archived outcome is the real one.
        recordHistory(result, outcome: outcome)
    }

    private func recordHistory(_ result: SessionResult, outcome: OutputRouter.Outcome?) {
        guard let historyStore, historyStore.isRecordingEnabled else { return }
        let draft = HistoryDraft(text: result.text,
                                 localeIdentifier: result.localeIdentifier,
                                 duration: result.duration,
                                 isPartial: result.isPartial,
                                 targetAppBundleID: sessionTargetApp?.bundleID,
                                 targetAppName: sessionTargetApp?.name,
                                 deliveryOutcomeRaw: outcome?.rawValue,
                                 segments: result.segments)
        historyStore.record(draft)
    }

    private func cancelDictation() {
        guard appState.session == .recording, sessionTask == nil else { return }
        // Same reasoning as `stopDictation`: the state has to move off
        // `.recording` before the first `await`, or repeated Escape presses
        // each spawn their own cancellation and stop the microphone twice.
        appState.transition(to: .finishing)
        appState.updateAudioLevel(0)
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            await engine.cancelSession()
            operationGeneration += 1
            appState.clearTranscript()
            appState.transition(to: .idle)
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(
                rebinder: makeShortcutRebinder(),
                onOpenHistory: { [weak self] in self?.openHistory() })
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

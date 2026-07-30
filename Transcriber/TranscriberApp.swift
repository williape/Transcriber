//
//  TranscriberApp.swift
//  Transcriber
//

import AppKit
import Carbon.HIToolbox
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
    /// panel never activates, is normally still the insertion target when it
    /// ends. The running instance is kept too, so delivery can bring it back if
    /// one of *our* windows had focus instead.
    private struct SessionTarget {
        let app: NSRunningApplication?
        let bundleID: String?
        let name: String?
    }
    private var sessionTarget: SessionTarget?
    /// Whether secure input was active when recording started — i.e. a password
    /// field was focused. Captured at the start (PRD §"startDictation") because
    /// focus can move before the transcript is delivered.
    private var sessionHadSecureInput = false
    /// Keeps the "couldn't save audio" alert to once per app run.
    private var hasWarnedAboutAudioFailure = false
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
        statusItemController.onTogglePauseHistory = { [weak self] in
            self?.togglePauseHistory()
        }
        statusItemController.isHistoryPaused = {
            Preferences.shared.historyPaused
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
            // Housekeeping at launch: drop expired entries, get back under the
            // audio cap, and settle any disagreement between the store and the
            // recordings folder.
            store.reconcileRecordings()
            store.prune()
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
            let actions = HistoryActions(
                insert: { [weak self] text in
                    await self?.reinsertAndReport(text) ?? .copiedToClipboard
                },
                retranscribe: { [weak self] entry, locale, replace in
                    guard let self else { return "" }
                    return try await retranscribe(entry, locale: locale, replace: replace)
                },
                currentProgress: { [weak self] in
                    self?.currentProgress()
                })
            historyWindowController = HistoryWindowController(store: historyStore, actions: actions)
        }
        historyWindowController?.show()
    }

    /// The current long-running step, if any, taken straight from `AppState` so
    /// the History window can't disagree with the menu bar icon.
    private func currentProgress() -> TranscriptionProgress? {
        switch appState.session {
        case .downloadingModel(let fraction):
            return TranscriptionProgress(label: "Downloading the language model…",
                                         fraction: fraction)
        case .transcribingFile(let fraction):
            return TranscriptionProgress(label: "Transcribing…", fraction: fraction)
        default:
            return nil
        }
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

    /// Re-runs transcription on an entry's retained audio.
    ///
    /// Uses the same `FileTranscriber` as a dropped file, and the same busy
    /// gating: it refuses while a dictation or another transcription is running,
    /// rather than competing for the analyzer.
    private func retranscribe(_ entry: HistoryEntry,
                              locale: Locale,
                              replace: Bool) async throws -> String {
        guard let historyStore else { throw RetranscribeError.historyUnavailable }
        guard let filename = entry.audioFilename else { throw RetranscribeError.noAudio }
        guard appState.session == .idle, sessionTask == nil else {
            throw RetranscribeError.busy
        }

        operationGeneration += 1
        let generation = operationGeneration
        appState.transition(to: .transcribingFile(progress: nil))
        defer {
            operationGeneration += 1
            appState.transition(to: .idle)
        }

        let text = try await fileTranscriber.transcribe(
            url: RecordingsDirectory.url(for: filename),
            locale: locale,
            modelDownloadProgress: progressSink(.modelDownload, generation: generation),
            onProgress: progressSink(.fileTranscription, generation: generation))

        historyStore.applyRetranscription(text,
                                          locale: locale,
                                          to: entry,
                                          replace: replace)
        return text
    }

    enum RetranscribeError: LocalizedError {
        case busy
        case noAudio
        case historyUnavailable

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Transcriber is busy. Wait for the current dictation or transcription to finish, then try again."
            case .noAudio:
                return "This entry has no retained audio to transcribe."
            case .historyUnavailable:
                return "The history store isn't available."
            }
        }
    }

    private func makeHistoryAdmin() -> HistoryAdmin {
        HistoryAdmin(
            storage: { [weak self] in
                HistoryAdmin.Storage(entryCount: self?.historyStore?.entryCount() ?? 0,
                                     audioBytes: RecordingsDirectory.totalBytes())
            },
            prune: { [weak self] in
                self?.historyStore?.prune()
            },
            deleteAll: { [weak self] in
                self?.historyStore?.deleteAll()
            },
            export: { [weak self] url in
                guard let self, let historyStore else { return }
                do {
                    let count = try historyStore.export(to: url)
                    logger.info("Exported \(count) entries")
                } catch {
                    presentError(error)
                }
            })
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
            appState.transition(to: .transcribingFile(progress: nil))
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
        sessionTarget = SessionTarget(app: target,
                                      bundleID: target?.bundleIdentifier,
                                      name: target?.localizedName)
        // Read before the session starts, while the focus that prompted it is
        // still the current one.
        sessionHadSecureInput = IsSecureEventInputEnabled()
        sessionTask = Task { @MainActor in
            defer { sessionTask = nil }
            appState.clearTranscript()
            do {
                try await engine.startSession(
                    locale: Preferences.shared.selectedLocale,
                    retainAudio: shouldRetainAudio(),
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
            } catch TranscriptionEngine.EngineError.transcriptionIncomplete(let partial, let underlying) {
                logger.error("Transcript truncated: \(underlying.localizedDescription, privacy: .public)")
                if partial.text.isEmpty {
                    // Nothing survived, so there's no entry to own the audio and
                    // nothing to insert — report the failure instead.
                    if let audio = partial.audio {
                        engine.discardRecording(audio)
                    }
                    presentError(underlying)
                } else {
                    // The stream died mid-session but the words we did get are
                    // still the user's — insert them rather than throwing them away.
                    await deliver(partial.markedPartial())
                }
            } catch {
                presentError(error)
            }
            appState.clearTranscript()
            appState.transition(to: .idle)
        }
    }

    /// Whether this session's audio should be kept.
    ///
    /// Nothing about a secure-input session is kept (see `isIncognito`), so the
    /// audio goes with the transcript.
    private func shouldRetainAudio() -> Bool {
        // No store means no entry will ever reference the file, so recording one
        // would only leave an orphan behind.
        guard historyStore != nil, !isIncognito() else { return false }
        let preferences = Preferences.shared
        return preferences.keepsTranscriptHistory
            && preferences.keepsAudioRecordings
            && !preferences.historyPaused
    }

    /// Whether this dictation must leave no trace — the PRD's "Incognito" row.
    ///
    /// Secure input means a password field is focused, so the words are very
    /// likely a credential. Archiving *the text* is as much the thing a dictation
    /// tool must not do as archiving the audio, which is why this gates the whole
    /// entry rather than just the recording.
    ///
    /// Checked both at session start and again at delivery: a session begun in an
    /// ordinary field and finished in a password one is exactly the case worth
    /// catching, and the reverse costs only one unarchived dictation.
    private func isIncognito() -> Bool {
        sessionHadSecureInput || IsSecureEventInputEnabled()
    }

    private func deliver(_ result: SessionResult) async {
        guard !result.text.isEmpty else {
            // Hold the panel briefly so the user learns why nothing was inserted.
            // Nothing was said, so neither the transcript nor the audio is worth
            // keeping.
            if let audio = result.audio {
                engine.discardRecording(audio)
            }
            appState.showNotice("No speech detected")
            try? await Task.sleep(for: .seconds(1.5))
            return
        }
        appState.updateTranscript(committed: result.text, volatile: "")
        appState.transition(to: .inserting)
        let outcome = await route(result.text)
        logger.info("Delivery outcome: \(String(describing: outcome), privacy: .public)")
        // After delivery, so the archived outcome is the real one.
        recordHistory(result, outcome: outcome)
    }

    /// Delivers a finished transcript to the app the session started in.
    ///
    /// The non-activating panel normally leaves that app frontmost, so a plain
    /// paste lands where the user was typing. But a dictation started while one of
    /// *our* windows had focus — Settings, History — would otherwise paste into
    /// that window while the history entry claimed the external app. When we're
    /// the active app, hand over to the same bring-it-back-and-confirm path
    /// "Insert Again" uses, which falls back to the clipboard if the target can't
    /// be reached.
    private func route(_ text: String) async -> OutputRouter.Outcome {
        let mode = Preferences.shared.insertionMode
        guard NSRunningApplication.current.isActive else {
            return await outputRouter.deliver(text, mode: mode)
        }
        return await outputRouter.reinsert(text, mode: mode, into: sessionTarget?.app)
    }

    /// Told once per app run: the transcript survived, the recording didn't.
    /// Silence would mean the user only discovers the loss when they go looking
    /// for a recording that was never written.
    private func warnAboutAudioFailureOnce() {
        guard !hasWarnedAboutAudioFailure else { return }
        hasWarnedAboutAudioFailure = true
        logger.error("Audio retention failed; warning the user")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Couldn't save the audio recording"
        alert.informativeText = """
        The transcript was kept, but Transcriber couldn't write this dictation's \
        audio — the disk may be full. It will try again next time; this message \
        won't repeat until you restart Transcriber.
        """
        alert.alertStyle = .warning
        alert.runModal()
    }

    /// Hands the finished session to the store — *after* the state machine has
    /// reached `.idle`.
    ///
    /// PRD F1.4: writing an entry must not gate the `inserting → idle`
    /// transition, and neither should the "couldn't save audio" alert, which
    /// would hold the panel open in `.inserting` for as long as it's up. The
    /// write still happens on the main actor through the store's main context
    /// (plan §"HistoryStore writes through the main context") — the task only
    /// lets the transition go first.
    ///
    /// Everything session-scoped is read *here*, synchronously, because the next
    /// dictation can begin before the task runs and would overwrite it.
    private func recordHistory(_ result: SessionResult, outcome: OutputRouter.Outcome?) {
        let target = sessionTarget
        let incognito = isIncognito()
        Task { @MainActor in
            archive(result, outcome: outcome, target: target, incognito: incognito)
            if result.audioFailed {
                warnAboutAudioFailureOnce()
            }
        }
    }

    private func archive(_ result: SessionResult,
                         outcome: OutputRouter.Outcome?,
                         target: SessionTarget?,
                         incognito: Bool) {
        guard !incognito else {
            // A password field was focused, so neither the words nor the
            // recording are the app's to keep.
            logger.info("Secure input; this dictation was not archived")
            if let audio = result.audio {
                engine.discardRecording(audio)
            }
            return
        }
        guard let historyStore else {
            // `shouldRetainAudio` already refuses without a store, so there
            // shouldn't be audio here — but an unowned recording must never be
            // left on disk.
            if let audio = result.audio {
                engine.discardRecording(audio)
            }
            return
        }
        guard historyStore.isRecordingEnabled else {
            // History was switched off (or paused) mid-session — the recording
            // shouldn't outlive the entry that would have referenced it.
            if let audio = result.audio {
                engine.discardRecording(audio)
            }
            return
        }
        let draft = HistoryDraft(text: result.text,
                                 localeIdentifier: result.localeIdentifier,
                                 duration: result.duration,
                                 isPartial: result.isPartial,
                                 targetAppBundleID: target?.bundleID,
                                 targetAppName: target?.name,
                                 deliveryOutcomeRaw: outcome?.rawValue,
                                 audioFilename: result.audio?.filename,
                                 audioByteCount: result.audio?.byteCount,
                                 segments: result.segments)
        guard historyStore.record(draft) else {
            // The entry was rolled back, so nothing references the recording.
            if let audio = result.audio {
                engine.discardRecording(audio)
            }
            return
        }
        // Keeping to the size cap is cheapest right after the thing that grew it.
        if result.audio != nil {
            historyStore.prune()
        }
    }

    private func togglePauseHistory() {
        Preferences.shared.historyPaused.toggle()
        logger.info("History paused: \(Preferences.shared.historyPaused)")
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
                onOpenHistory: { [weak self] in self?.openHistory() },
                historyAdmin: makeHistoryAdmin())
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

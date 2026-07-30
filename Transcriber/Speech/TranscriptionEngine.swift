//
//  TranscriptionEngine.swift
//  Transcriber
//

import AVFoundation
import CoreMedia
import Foundation
import Speech
import os

/// Everything a finished session produced. Returned instead of a bare `String`
/// so the transcript, its timeline and the session metadata reach the history
/// store together — including on the truncated path, where the partial result
/// is just as worth keeping.
nonisolated struct SessionResult: Sendable {
    let text: String
    let segments: [TranscriptSegment]
    /// BCP-47 identifier of the locale actually used.
    let localeIdentifier: String
    let duration: TimeInterval
    let isPartial: Bool
    /// Retained audio, when the user asked for it and the write succeeded.
    let audio: SessionAudioRecorder.Recorded?
    /// The user asked for audio and it couldn't be written — worth telling them,
    /// unlike the ordinary "retention is off" case.
    let audioFailed: Bool

    func markedPartial() -> SessionResult {
        SessionResult(text: text,
                      segments: segments,
                      localeIdentifier: localeIdentifier,
                      duration: duration,
                      isPartial: true,
                      audio: audio,
                      audioFailed: audioFailed)
    }
}

/// Owns one live dictation session: mic permission, model availability,
/// SpeechAnalyzer + SpeechTranscriber, and the volatile/committed result split.
@MainActor
final class TranscriptionEngine {
    enum EngineError: LocalizedError {
        case microphonePermissionDenied
        case localeNotSupported(Locale)
        case noCompatibleAudioFormat
        case sessionAlreadyRunning
        /// The results stream failed part-way through; `partial` is what was
        /// committed before it died, so the caller can still use it.
        case transcriptionIncomplete(partial: SessionResult, underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone access is denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone."
            case .localeNotSupported(let locale):
                return "Transcription isn't supported for \(locale.identifier)."
            case .noCompatibleAudioFormat:
                return "No compatible audio format is available for transcription."
            case .sessionAlreadyRunning:
                return "A dictation session is already in progress."
            case .transcriptionIncomplete(_, let underlying):
                return "Transcription stopped early. (\(underlying.localizedDescription))"
            }
        }
    }

    /// Called on the main actor with the full committed text and current volatile remainder.
    var onTranscript: ((_ committed: String, _ volatile: String) -> Void)?

    /// Called on the main actor with the mic input level (0...1) while recording.
    var onLevel: ((Double) -> Void)?

    private let microphone = MicrophoneCapture()
    private var recorder: SessionAudioRecorder?
    /// Set when audio was wanted but the recorder couldn't even be opened.
    private var recorderUnavailable = false
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var committed = ""
    /// Committed spans with their place in the session's audio timeline.
    private var segments: [TranscriptSegment] = []
    /// Locale and start time of the running session, for the `SessionResult`.
    private var sessionLocaleIdentifier = ""
    private var sessionStartedAt: Date?
    /// Set when `transcriber.results` dies mid-session, so `finishSession()`
    /// can report a truncated transcript instead of passing it off as complete.
    private var streamError: (any Error)?
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Engine")

    /// Prepares (permission, model) and starts the streaming session.
    func startSession(locale requestedLocale: Locale,
                      retainAudio: Bool,
                      modelDownloadProgress: @escaping @Sendable (Double) -> Void) async throws {
        guard analyzer == nil, resultsTask == nil else {
            throw EngineError.sessionAlreadyRunning
        }
        guard await requestMicrophonePermission() else {
            throw EngineError.microphonePermissionDenied
        }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw EngineError.localeNotSupported(requestedLocale)
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])

        try await ModelAssetManager.ensureModel(for: transcriber,
                                                locale: locale,
                                                onProgress: modelDownloadProgress)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noCompatibleAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.transcriber = transcriber
        self.analyzer = analyzer
        committed = ""
        segments = []
        sessionLocaleIdentifier = locale.identifier(.bcp47)
        sessionStartedAt = nil
        streamError = nil
        recorderUnavailable = false

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.committed += text
                        self.appendSegment(text: text, range: result.range)
                        self.onTranscript?(self.committed, "")
                    } else {
                        self.onTranscript?(self.committed, text)
                    }
                }
            } catch {
                self?.logger.error("Results stream ended with error: \(error, privacy: .public)")
                self?.streamError = error
            }
        }

        // Everything above is now owned by `self`, so any failure from here on
        // has to unwind the whole session — otherwise the analyzer, the input
        // continuation and the results task outlive the failed start and the
        // next session leaks them.
        do {
            try await analyzer.start(inputSequence: stream)
            // Timed from when audio actually starts flowing, so a slow model
            // download doesn't inflate the recorded duration.
            let startedAt = Date()
            sessionStartedAt = startedAt
            if retainAudio {
                // A recorder that can't be opened costs the user their audio,
                // not their dictation — but they do get told once.
                do {
                    recorder = try SessionAudioRecorder(format: format, startedAt: startedAt)
                } catch {
                    recorderUnavailable = true
                    logger.error("Audio retention unavailable this session: \(error.localizedDescription, privacy: .public)")
                }
            }
            let recorder = self.recorder
            try microphone.start(targetFormat: format, onLevel: { [weak self] level in
                guard let self else { return }
                Task { @MainActor in
                    self.onLevel?(level)
                }
            }, onBuffer: { buffer in
                continuation.yield(AnalyzerInput(buffer: buffer))
                recorder?.append(buffer)
            })
        } catch {
            await cancelSession()
            throw error
        }
        logger.info("Session started (locale \(locale.identifier(.bcp47), privacy: .public))")
    }

    /// Stops capture, finalizes remaining audio, and returns the full transcript.
    /// Throws `.transcriptionIncomplete` (carrying whatever was committed) when
    /// the results stream failed part-way through.
    func finishSession() async throws -> SessionResult {
        microphone.stop()
        // Capture the span now: the mic has just stopped, so this is the end of
        // the audio, and the finalize/await below can take a while.
        let duration = sessionStartedAt.map { -$0.timeIntervalSinceNow } ?? 0
        let recorder = self.recorder
        self.recorder = nil
        let outcome = await recorder?.finish()
        inputContinuation?.finish()
        inputContinuation = nil
        // Hand ownership to locals before any `await`, so the engine is left in
        // a clean, reusable state no matter which of these throws.
        let analyzer = self.analyzer
        let resultsTask = self.resultsTask
        tearDown()

        do {
            try await analyzer?.finalizeAndFinishThroughEndOfInput()
        } catch {
            await analyzer?.cancelAndFinishNow()
            resultsTask?.cancel()
            // Cancelling isn't waiting: the task's `catch` assigns `streamError`
            // and its body calls `onTranscript`, so letting it outlive this
            // method lets it land in whatever session comes next.
            await resultsTask?.value
            // This session is reported as the finalize failure, not as a
            // truncated transcript, so the cancellation the await just collected
            // must not be left for the next one to trip over.
            streamError = nil
            // The recording was already finalized above, and this session now
            // ends with no `SessionResult` — so no history entry will ever
            // reference the file. Take it with us rather than leaving an orphan
            // for the next launch's reconcile pass to find.
            if case .recorded(let recorded) = outcome {
                RecordingsDirectory.delete(filename: recorded.filename)
            }
            throw error
        }
        await resultsTask?.value

        let result = makeResult(duration: duration,
                                isPartial: streamError != nil,
                                outcome: outcome)
        if let streamError {
            self.streamError = nil
            logger.error("Session finished with a truncated transcript (\(self.committed.count) characters)")
            throw EngineError.transcriptionIncomplete(partial: result, underlying: streamError)
        }
        logger.info("Session finished (\(self.committed.count) characters, \(Int(duration))s)")
        return result
    }

    private func makeResult(duration: TimeInterval,
                            isPartial: Bool,
                            outcome: SessionAudioRecorder.Outcome?) -> SessionResult {
        var audio: SessionAudioRecorder.Recorded?
        // An `.empty` recording is only a failure if there was something to
        // record; a silent session legitimately produces no audio.
        var failed = recorderUnavailable
        switch outcome {
        case .recorded(let recorded):
            audio = recorded
        case .failed:
            failed = true
        case .empty:
            failed = failed || !committed.isEmpty
        case nil:
            break
        }
        return SessionResult(text: committed,
                             segments: segments,
                             localeIdentifier: sessionLocaleIdentifier,
                             duration: duration,
                             isPartial: isPartial,
                             audio: audio,
                             audioFailed: failed)
    }

    /// Drops a finished session's audio — a silent dictation isn't worth keeping
    /// a recording of.
    func discardRecording(_ audio: SessionAudioRecorder.Recorded) {
        RecordingsDirectory.delete(filename: audio.filename)
    }

    /// Records a committed span against the analyzer's timeline. Ranges can be
    /// non-numeric (`CMTime.invalid`/`indefinite`) — those are dropped rather
    /// than persisted as NaN seconds.
    private func appendSegment(text: String, range: CMTimeRange) {
        guard range.start.isNumeric, range.duration.isNumeric else { return }
        segments.append(TranscriptSegment(start: range.start.seconds,
                                          end: range.end.seconds,
                                          text: text))
    }

    /// Abandons the session, discarding all results. Safe to call on a
    /// half-started or already-finished session.
    func cancelSession() async {
        microphone.stop()
        let recorder = self.recorder
        self.recorder = nil
        await recorder?.discard()
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        let resultsTask = self.resultsTask
        tearDown()

        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        // Awaited, not just cancelled: the task writes `streamError` from its
        // `catch` and pushes text through `onTranscript`, and a session that
        // starts while it's still unwinding would inherit both. Clearing the
        // state below only helps if nothing can still be writing to it.
        await resultsTask?.value
        committed = ""
        segments = []
        sessionStartedAt = nil
        streamError = nil
        logger.info("Session cancelled")
    }

    private func tearDown() {
        resultsTask = nil
        analyzer = nil
        transcriber = nil
    }

    private func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        logger.info("Mic authorization status: \(status.rawValue) (0=notDetermined 1=restricted 2=denied 3=authorized)")
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

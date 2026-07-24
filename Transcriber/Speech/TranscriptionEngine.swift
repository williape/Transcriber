//
//  TranscriptionEngine.swift
//  Transcriber
//

import AVFoundation
import Foundation
import Speech
import os

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
        case transcriptionIncomplete(partial: String, underlying: any Error)

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
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var committed = ""
    /// Set when `transcriber.results` dies mid-session, so `finishSession()`
    /// can report a truncated transcript instead of passing it off as complete.
    private var streamError: (any Error)?
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Engine")

    /// Prepares (permission, model) and starts the streaming session.
    func startSession(locale requestedLocale: Locale,
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
        streamError = nil

        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        inputContinuation = continuation

        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    guard let self else { return }
                    let text = String(result.text.characters)
                    if result.isFinal {
                        self.committed += text
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
            try microphone.start(targetFormat: format, onLevel: { [weak self] level in
                guard let self else { return }
                Task { @MainActor in
                    self.onLevel?(level)
                }
            }, onBuffer: { buffer in
                continuation.yield(AnalyzerInput(buffer: buffer))
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
    func finishSession() async throws -> String {
        microphone.stop()
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
            throw error
        }
        await resultsTask?.value

        if let streamError {
            self.streamError = nil
            logger.error("Session finished with a truncated transcript (\(self.committed.count) characters)")
            throw EngineError.transcriptionIncomplete(partial: committed, underlying: streamError)
        }
        logger.info("Session finished (\(self.committed.count) characters)")
        return committed
    }

    /// Abandons the session, discarding all results. Safe to call on a
    /// half-started or already-finished session.
    func cancelSession() async {
        microphone.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        let analyzer = self.analyzer
        let resultsTask = self.resultsTask
        tearDown()

        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        committed = ""
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

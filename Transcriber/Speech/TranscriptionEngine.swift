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

        var errorDescription: String? {
            switch self {
            case .microphonePermissionDenied:
                return "Microphone access is denied. Enable it in System Settings ▸ Privacy & Security ▸ Microphone."
            case .localeNotSupported(let locale):
                return "Transcription isn't supported for \(locale.identifier)."
            case .noCompatibleAudioFormat:
                return "No compatible audio format is available for transcription."
            }
        }
    }

    /// Called on the main actor with the full committed text and current volatile remainder.
    var onTranscript: ((_ committed: String, _ volatile: String) -> Void)?

    private let microphone = MicrophoneCapture()
    private var analyzer: SpeechAnalyzer?
    private var transcriber: SpeechTranscriber?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var committed = ""
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Engine")

    /// Prepares (permission, model) and starts the streaming session.
    func startSession(locale requestedLocale: Locale,
                      modelDownloadProgress: @escaping @Sendable (Double) -> Void) async throws {
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
        self.transcriber = transcriber

        try await ModelAssetManager.ensureModel(for: transcriber,
                                                locale: locale,
                                                onProgress: modelDownloadProgress)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw EngineError.noCompatibleAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        committed = ""

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
            }
        }

        try await analyzer.start(inputSequence: stream)
        try microphone.start(targetFormat: format) { buffer in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        logger.info("Session started (locale \(locale.identifier(.bcp47), privacy: .public))")
    }

    /// Stops capture, finalizes remaining audio, and returns the full transcript.
    func finishSession() async throws -> String {
        microphone.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        try await analyzer?.finalizeAndFinishThroughEndOfInput()
        await resultsTask?.value
        tearDown()
        logger.info("Session finished (\(self.committed.count) characters)")
        return committed
    }

    /// Abandons the session, discarding all results.
    func cancelSession() async {
        microphone.stop()
        inputContinuation?.finish()
        inputContinuation = nil
        await analyzer?.cancelAndFinishNow()
        resultsTask?.cancel()
        tearDown()
        committed = ""
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

//
//  FileTranscriber.swift
//  Transcriber
//

import AVFoundation
import Foundation
import Speech
import os

/// Batch transcription of audio/video files via `analyzeSequence(from:)`,
/// which streams the file internally — safe for webinar-length input.
@MainActor
final class FileTranscriber {
    enum FileError: LocalizedError {
        case unreadable(String)
        case localeNotSupported(Locale)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "\"\(name)\" can't be read as an audio file."
            case .localeNotSupported(let locale):
                return "Transcription isn't supported for \(locale.identifier)."
            }
        }
    }

    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "FileTranscriber")

    func transcribe(url: URL,
                    locale requestedLocale: Locale,
                    modelDownloadProgress: @escaping @Sendable (Double) -> Void,
                    onProgress: @escaping @Sendable (Double) -> Void) async throws -> String {
        let audioFile: AVAudioFile
        do {
            audioFile = try AVAudioFile(forReading: url)
        } catch {
            logger.error("Cannot open \(url.lastPathComponent, privacy: .public): \(error, privacy: .public)")
            throw FileError.unreadable(url.lastPathComponent)
        }
        let duration = Double(audioFile.length) / audioFile.processingFormat.sampleRate
        logger.info("Transcribing \(url.lastPathComponent, privacy: .public) (\(Int(duration))s)")

        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw FileError.localeNotSupported(requestedLocale)
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        try await ModelAssetManager.ensureModel(for: transcriber,
                                                locale: locale,
                                                onProgress: modelDownloadProgress)

        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let resultsTask = Task<String, Error> {
            var text = ""
            for try await result in transcriber.results {
                text += String(result.text.characters)
                if duration > 0 {
                    let end = result.range.end.seconds
                    onProgress(min(max(end / duration, 0), 1))
                }
            }
            return text
        }

        do {
            if let lastSampleTime = try await analyzer.analyzeSequence(from: audioFile) {
                try await analyzer.finalizeAndFinish(through: lastSampleTime)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            resultsTask.cancel()
            throw error
        }

        let text = try await resultsTask.value
        logger.info("Finished \(url.lastPathComponent, privacy: .public): \(text.count) characters")
        return text
    }
}

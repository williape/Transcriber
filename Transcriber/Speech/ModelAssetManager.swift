//
//  ModelAssetManager.swift
//  Transcriber
//

import Foundation
import Speech
import os

/// Ensures the on-device speech model for a locale is installed via the
/// system asset catalog. The one network touch of the app (first run only).
enum ModelAssetManager {
    enum ModelError: LocalizedError {
        case downloadFailed(underlying: any Error)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let underlying):
                return "The speech model couldn't be downloaded. Check your internet connection and try again. (\(underlying.localizedDescription))"
            }
        }
    }

    private static let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "ModelAssets")

    /// Downloads and installs the model supporting `transcriber` if missing.
    /// `onProgress` receives fractions in 0...1 only when a download actually runs.
    static func ensureModel(for transcriber: SpeechTranscriber,
                            locale: Locale,
                            onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let installed = await SpeechTranscriber.installedLocales
        if installed.map({ $0.identifier(.bcp47) }).contains(locale.identifier(.bcp47)) {
            logger.info("Model already installed for \(locale.identifier(.bcp47), privacy: .public)")
            return
        }

        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            logger.info("No installation request needed for \(locale.identifier(.bcp47), privacy: .public)")
            return
        }

        logger.info("Downloading speech model for \(locale.identifier(.bcp47), privacy: .public)")
        let progress = request.progress
        let poller = Task {
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { poller.cancel() }

        do {
            try await request.downloadAndInstall()
        } catch {
            logger.error("Model download failed: \(error, privacy: .public)")
            throw ModelError.downloadFailed(underlying: error)
        }
        onProgress(1.0)
        logger.info("Speech model installed")
    }
}

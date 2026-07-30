//
//  AppState.swift
//  Transcriber
//

import Foundation
import Observation
import os

/// Single source of truth for the app's session state machine:
/// `idle → recording → finishing → inserting → idle`, with file transcription
/// and model download as parallel modes. Transitions are driven by the
/// orchestration in AppDelegate; observers (menu bar, panel) react.
@MainActor
@Observable
final class AppState {
    enum Session: Equatable {
        case idle
        case recording
        case finishing
        case inserting
        /// `progress` is nil until the first real fraction arrives — a
        /// determinate bar pinned at zero reads as "stuck", so the UI shows an
        /// indeterminate one until there's something true to draw.
        case transcribingFile(progress: Double?)
        case downloadingModel(progress: Double?)
    }

    private(set) var session: Session = .idle

    /// Live transcript shown in the panel.
    private(set) var committedText = ""
    private(set) var volatileText = ""

    /// Microphone input level, 0...1, updated ~10×/s while recording.
    private(set) var audioLevel: Double = 0

    /// Transient message shown in the panel instead of the transcript
    /// (e.g. "No speech detected" before dismissal).
    private(set) var notice: String?

    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "AppState")

    func transition(to newSession: Session) {
        let oldSession = session
        session = newSession
        // Progress ticks within the same mode would spam the log.
        if !Self.sameKind(oldSession, newSession) {
            logger.info("Session: \(String(describing: oldSession), privacy: .public) → \(String(describing: newSession), privacy: .public)")
        }
    }

    func updateTranscript(committed: String, volatile: String) {
        committedText = committed
        volatileText = volatile
    }

    func clearTranscript() {
        committedText = ""
        volatileText = ""
        notice = nil
    }

    func updateAudioLevel(_ level: Double) {
        audioLevel = level
    }

    func showNotice(_ text: String) {
        notice = text
    }

    private static func sameKind(_ a: Session, _ b: Session) -> Bool {
        switch (a, b) {
        case (.transcribingFile, .transcribingFile), (.downloadingModel, .downloadingModel):
            return true
        default:
            return a == b
        }
    }
}

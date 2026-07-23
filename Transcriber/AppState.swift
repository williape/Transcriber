//
//  AppState.swift
//  Transcriber
//

import Foundation
import Observation
import os

/// Single source of truth for the app's session state machine:
/// `idle → recording → finishing → inserting → idle`, with file transcription
/// and model download as parallel modes.
@MainActor
@Observable
final class AppState {
    enum Session: Equatable {
        case idle
        case recording
        case finishing
        case inserting
        case transcribingFile(progress: Double)
        case downloadingModel(progress: Double)
    }

    private(set) var session: Session = .idle

    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "AppState")

    func toggleDictation() {
        switch session {
        case .idle:
            session = .recording
            logger.info("Session: idle → recording")
        case .recording:
            // Phase 1: no speech pipeline yet, so skip finishing/inserting.
            session = .idle
            logger.info("Session: recording → idle")
        case .finishing, .inserting, .transcribingFile, .downloadingModel:
            logger.info("Toggle ignored in state \(String(describing: self.session), privacy: .public)")
        }
    }

    /// Esc: abandon the session without producing output.
    func cancelDictation() {
        guard session == .recording else { return }
        session = .idle
        logger.info("Session: recording → idle (cancelled)")
    }
}

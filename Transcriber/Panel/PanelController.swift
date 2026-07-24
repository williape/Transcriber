//
//  PanelController.swift
//  Transcriber
//

import AppKit
import Observation
import SwiftUI
import os

/// Shows/hides the floating panel in response to session state. Because the
/// panel is never key, Esc can't arrive as a key event — instead a plain-Esc
/// Carbon hotkey is registered only while a recording is live (see
/// `updateEscapeRegistration`).
@MainActor
final class PanelController {
    private let appState: AppState
    private let hotkeyManager: HotkeyManager
    private var panel: FloatingPanel?
    private var escapeHotkeyID: HotkeyManager.HotkeyID?
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Panel")

    init(appState: AppState, hotkeyManager: HotkeyManager) {
        self.appState = appState
        self.hotkeyManager = hotkeyManager
        observeState()
        sessionChanged()
    }

    private func observeState() {
        withObservationTracking {
            _ = appState.session
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sessionChanged()
                self.observeState()
            }
        }
    }

    /// What to do when Esc is pressed while a recording is live.
    var onEscape: (() -> Void)?

    private func sessionChanged() {
        switch appState.session {
        case .recording, .finishing, .inserting, .downloadingModel, .transcribingFile:
            show()
        case .idle:
            hide()
        }
        updateEscapeRegistration()
    }

    /// Esc is a *global* Carbon hotkey: while registered, no other app sees the
    /// key. So it's bound to the one state it acts on — cancelling a live
    /// recording — rather than to panel visibility. The panel is also up during
    /// file transcription and model downloads, where Esc does nothing; holding
    /// it hostage for the length of a half-hour transcription would be hostile.
    private func updateEscapeRegistration() {
        if appState.session == .recording {
            registerEscape()
        } else {
            unregisterEscape()
        }
    }

    private func show() {
        guard panel == nil || !panel!.isVisible else { return }
        let panel = self.panel ?? makePanel()
        position(panel)
        // orderFrontRegardless, NOT makeKeyAndOrderFront — the panel must not
        // take focus from the user's target app.
        panel.orderFrontRegardless()
        logger.info("Panel shown")
    }

    private func hide() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        logger.info("Panel hidden")
    }

    private func makePanel() -> FloatingPanel {
        let size = DictationView.panelSize
        let panel = FloatingPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = NSHostingView(rootView: DictationView(appState: appState))
        self.panel = panel
        return panel
    }

    /// Centered horizontally, near the bottom of the active screen.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        let origin = NSPoint(x: visible.midX - size.width / 2,
                             y: visible.minY + 140)
        panel.setFrameOrigin(origin)
    }

    private func registerEscape() {
        guard escapeHotkeyID == nil else { return }
        escapeHotkeyID = hotkeyManager.register(.escape) { [weak self] in
            self?.onEscape?()
        }
        if escapeHotkeyID == nil {
            logger.error("Could not register Esc while panel visible")
        }
    }

    private func unregisterEscape() {
        if let escapeHotkeyID {
            hotkeyManager.unregister(escapeHotkeyID)
            self.escapeHotkeyID = nil
        }
    }
}

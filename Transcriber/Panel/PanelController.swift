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
final class PanelController: NSObject {
    private let appState: AppState
    private let hotkeyManager: HotkeyManager
    private let preferences = Preferences.shared
    private var panel: FloatingPanel?
    private var escapeHotkeyID: HotkeyManager.HotkeyID?
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Panel")

    init(appState: AppState, hotkeyManager: HotkeyManager) {
        self.appState = appState
        self.hotkeyManager = hotkeyManager
        super.init()
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
        panel.delegate = self
        self.panel = panel
        return panel
    }

    /// Forgets where the user dragged the panel; it returns to the default spot
    /// the next time it appears — or immediately, if it's up right now.
    func resetPosition() {
        preferences.panelOrigin = nil
        if let panel {
            panel.setFrameOrigin(defaultOrigin(for: panel.frame.size))
        }
        logger.info("Panel position reset")
    }

    /// Wherever the user last dragged it, or — the first time — centered
    /// horizontally near the bottom of the active screen.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        if let saved = preferences.panelOrigin {
            panel.setFrameOrigin(onScreenOrigin(for: NSRect(origin: saved, size: size)))
        } else {
            panel.setFrameOrigin(defaultOrigin(for: size))
        }
    }

    private func defaultOrigin(for size: NSSize) -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let visible = screen.visibleFrame
        return NSPoint(x: visible.midX - size.width / 2,
                       y: visible.minY + 140)
    }

    /// A saved position can be stale — the display it was on may be gone, or
    /// smaller than it was. Clamp the frame into whichever screen it overlaps
    /// most (the main screen if it overlaps none) so the panel can never come
    /// back somewhere the user can't see or reach it.
    private func onScreenOrigin(for frame: NSRect) -> NSPoint {
        let overlapped = NSScreen.screens
            .map { ($0, area(frame.intersection($0.visibleFrame))) }
            .max { $0.1 < $1.1 }
        let screen = (overlapped?.1 ?? 0) > 0 ? overlapped?.0 : (NSScreen.main ?? NSScreen.screens.first)
        guard let visible = screen?.visibleFrame else { return frame.origin }
        return NSPoint(x: min(max(frame.minX, visible.minX), visible.maxX - frame.width),
                       y: min(max(frame.minY, visible.minY), visible.maxY - frame.height))
    }

    private func area(_ rect: NSRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
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

extension PanelController: NSWindowDelegate {
    /// Remember where the user put it, so the next dictation starts there.
    func windowDidMove(_ notification: Notification) {
        guard let panel, panel === notification.object as? NSWindow else { return }
        preferences.panelOrigin = panel.frame.origin
    }
}

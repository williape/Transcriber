//
//  StatusItemController.swift
//  Transcriber
//

import AppKit
import Observation
import os

/// Owns the `NSStatusItem`, its menu, and the icon-per-state mapping.
@MainActor
final class StatusItemController: NSObject {
    var onToggleDictation: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let appState: AppState
    private let statusItem: NSStatusItem
    private let dictationItem: NSMenuItem
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "StatusItem")

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        self.dictationItem = NSMenuItem(title: "Start Dictation", action: nil, keyEquivalent: "")
        super.init()

        buildMenu()
        observeState()
        refresh()
    }

    private func buildMenu() {
        let menu = NSMenu()

        dictationItem.target = self
        dictationItem.action = #selector(toggleDictation)
        menu.addItem(dictationItem)

        // No action yet — stays disabled until Phase 5.
        menu.addItem(NSMenuItem(title: "Transcribe File…", action: nil, keyEquivalent: ""))

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit Transcriber",
                                  action: #selector(NSApplication.terminate(_:)),
                                  keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Re-arms Observation tracking each time the session state changes.
    private func observeState() {
        withObservationTracking {
            _ = appState.session
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.observeState()
            }
        }
    }

    private func refresh() {
        let symbolName: String
        let description: String
        switch appState.session {
        case .idle:
            symbolName = "mic"
            description = "Transcriber idle"
        case .recording:
            symbolName = "mic.fill"
            description = "Transcriber recording"
        case .finishing, .inserting:
            symbolName = "mic.badge.xmark"
            description = "Transcriber finishing"
        case .transcribingFile:
            symbolName = "waveform"
            description = "Transcriber transcribing file"
        case .downloadingModel:
            symbolName = "arrow.down.circle"
            description = "Transcriber downloading model"
        }

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image

        dictationItem.title = appState.session == .recording ? "Stop Dictation" : "Start Dictation"
    }

    @objc private func toggleDictation() {
        onToggleDictation?()
    }

    @objc private func openSettings() {
        onOpenSettings?()
    }
}

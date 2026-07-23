//
//  StatusItemController.swift
//  Transcriber
//

import AppKit
import Observation
import UniformTypeIdentifiers
import os

/// Owns the `NSStatusItem`, its menu, and the icon-per-state mapping.
@MainActor
final class StatusItemController: NSObject {
    var onToggleDictation: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onTranscribeFilePrompt: (() -> Void)?
    var onFileDropped: ((URL) -> Void)?

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
        installDragTarget()
        observeState()
        refresh()
    }

    /// Overlay accepting audio/video file drops on the menu bar icon.
    private func installDragTarget() {
        guard let button = statusItem.button else { return }
        let dragView = StatusItemDragView(frame: button.bounds)
        dragView.autoresizingMask = [.width, .height]
        dragView.onFileDropped = { [weak self] url in
            self?.onFileDropped?(url)
        }
        button.addSubview(dragView)
    }

    private func buildMenu() {
        let menu = NSMenu()

        dictationItem.target = self
        dictationItem.action = #selector(toggleDictation)
        menu.addItem(dictationItem)

        let transcribeItem = NSMenuItem(title: "Transcribe File…",
                                        action: #selector(transcribeFilePrompt),
                                        keyEquivalent: "")
        transcribeItem.target = self
        menu.addItem(transcribeItem)

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

    @objc private func transcribeFilePrompt() {
        onTranscribeFilePrompt?()
    }
}

/// Transparent drag destination overlaying the status button; forwards clicks
/// so the menu still opens.
private final class StatusItemDragView: NSView {
    var onFileDropped: ((URL) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func mouseDown(with event: NSEvent) {
        (superview as? NSStatusBarButton)?.performClick(nil)
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        acceptableFileURL(from: sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let url = acceptableFileURL(from: sender) else { return false }
        onFileDropped?(url)
        return true
    }

    private func acceptableFileURL(from info: any NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                             options: options) as? [URL],
              let url = urls.first,
              let type = UTType(filenameExtension: url.pathExtension),
              type.conforms(to: .audiovisualContent) else {
            return nil
        }
        return url
    }
}

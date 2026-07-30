//
//  StatusItemController.swift
//  Transcriber
//

import AppKit
import Observation
import UniformTypeIdentifiers
import os

/// One entry as the menu needs it — a title to show and the text to insert.
struct RecentTranscript {
    let title: String
    let text: String
}

/// Owns the `NSStatusItem`, its menu, and the icon-per-state mapping.
@MainActor
final class StatusItemController: NSObject {
    var onToggleDictation: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onTranscribeFilePrompt: (() -> Void)?
    var onFileDropped: ((URL) -> Void)?
    var onOpenHistory: (() -> Void)?
    var onInsertTranscript: ((String) -> Void)?
    var onCopyLastTranscript: (() -> Void)?
    /// Asked for fresh entries each time the submenu opens.
    var recentTranscripts: (() -> [RecentTranscript])?

    private let appState: AppState
    private let statusItem: NSStatusItem
    private let dictationItem: NSMenuItem
    private let recentMenu = NSMenu()
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

        let historyItem = NSMenuItem(title: "History…", action: #selector(openHistory), keyEquivalent: "y")
        historyItem.target = self
        menu.addItem(historyItem)

        let recentItem = NSMenuItem(title: "Recent Transcripts", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)

        let copyLastItem = NSMenuItem(title: "Copy Last Transcript",
                                      action: #selector(copyLastTranscript),
                                      keyEquivalent: "")
        copyLastItem.target = self
        menu.addItem(copyLastItem)

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

    /// Re-arms Observation tracking each time the session state (or, while
    /// recording, the mic level driving the icon animation) changes.
    private func observeState() {
        withObservationTracking {
            _ = appState.session
            _ = appState.audioLevel
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refresh()
                self.observeState()
            }
        }
    }

    private func refresh() {
        let image: NSImage?
        switch appState.session {
        case .idle:
            image = NSImage(systemSymbolName: "mic", accessibilityDescription: "Transcriber idle")
        case .recording:
            // Variable-color waveform driven by the live mic level = the
            // recording animation; a small floor keeps it visibly "on" in silence.
            image = NSImage(systemSymbolName: "waveform",
                            variableValue: max(appState.audioLevel, 0.1),
                            accessibilityDescription: "Transcriber recording")
        case .finishing, .inserting:
            image = NSImage(systemSymbolName: "mic.badge.xmark", accessibilityDescription: "Transcriber finishing")
        case .transcribingFile:
            image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "Transcriber transcribing file")
        case .downloadingModel:
            image = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Transcriber downloading model")
        }

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

    @objc private func openHistory() {
        onOpenHistory?()
    }

    @objc private func copyLastTranscript() {
        onCopyLastTranscript?()
    }

    @objc private func insertRecentTranscript(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        onInsertTranscript?(text)
    }
}

extension StatusItemController: NSMenuDelegate {
    /// Rebuilt on every open rather than kept in sync — the list is short and
    /// the menu is the only thing that reads it.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let recents = recentTranscripts?() ?? []
        guard !recents.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Transcripts", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for recent in recents {
            let item = NSMenuItem(title: recent.title,
                                  action: #selector(insertRecentTranscript(_:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = recent.text
            menu.addItem(item)
        }
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

//
//  HistoryWindowController.swift
//  Transcriber
//

import AppKit
import SwiftData
import SwiftUI

/// Standard window listing archived dictations.
///
/// Deliberately not the floating panel: search and text selection need key
/// focus, which the dictation panel is built never to take.
@MainActor
final class HistoryWindowController: NSWindowController {
    convenience init(store: HistoryStore, actions: HistoryActions) {
        let root = HistoryListView(actions: actions, store: store)
            .modelContainer(store.container)
        let window = NSWindow(contentViewController: NSHostingController(rootView: root))
        window.title = "Transcription History"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 860, height: 520))
        window.minSize = NSSize(width: 640, height: 360)
        window.setFrameAutosaveName("HistoryWindow")
        window.center()
        self.init(window: window)
    }

    func show() {
        // LSUIElement apps aren't active by default; activate so search works.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

/// The window's way back into the app's plumbing, in the same closure-bag style
/// as `ShortcutRebinder` — the views stay free of `AppDelegate`.
@MainActor
struct HistoryActions {
    /// Re-inserts into whatever app the user was last in, honouring their
    /// insertion-mode preference. Returns what actually happened.
    var insert: (String) async -> OutputRouter.Outcome

    /// Re-runs transcription on an entry's retained audio, either replacing its
    /// text or saving a new entry (with its own copy of the audio). Returns the
    /// new transcript.
    var retranscribe: (HistoryEntry, Locale, Bool) async throws -> String

    /// Live progress of whatever the app is doing, read from `AppState` — the
    /// same source the menu bar icon and the dictation panel use, rather than a
    /// second progress channel that could disagree with them. Read from a view
    /// body so Observation picks up the dependency.
    var currentProgress: () -> TranscriptionProgress?

    static let noop = HistoryActions(insert: { _ in .copiedToClipboard },
                                     retranscribe: { _, _, _ in "" },
                                     currentProgress: { nil })
}

/// A step the user is waiting on, labelled so a model download doesn't look like
/// a stalled transcription.
struct TranscriptionProgress {
    let label: String
    /// nil until the operation has reported a real fraction — see
    /// `AppState.Session`.
    let fraction: Double?
}

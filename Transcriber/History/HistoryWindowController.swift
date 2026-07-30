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
    convenience init(container: ModelContainer, actions: HistoryActions) {
        let root = HistoryListView(actions: actions)
            .modelContainer(container)
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

    static let noop = HistoryActions(insert: { _ in .copiedToClipboard })
}

//
//  TranscriptWindowController.swift
//  Transcriber
//

import AppKit
import SwiftUI

/// Standard window presenting a finished file transcription.
@MainActor
final class TranscriptWindowController: NSWindowController {
    convenience init(text: String, sourceURL: URL) {
        let sourceName = sourceURL.deletingPathExtension().lastPathComponent
        let hosting = NSHostingController(rootView: TranscriptResultView(text: text,
                                                                         sourceName: sourceName))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Transcript — \(sourceURL.lastPathComponent)"
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 560, height: 440))
        window.center()
        self.init(window: window)
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

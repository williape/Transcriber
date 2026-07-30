//
//  FrontmostAppTracker.swift
//  Transcriber
//

import AppKit
import os

/// Remembers the last app that was frontmost *other than us*.
///
/// Live dictation doesn't need this — the panel is non-activating, so the target
/// app never stops being frontmost. Re-inserting from the History window or the
/// menu bar does: both take focus, so by the time the user clicks, the app they
/// want the text in is no longer frontmost and `NSWorkspace` would just report
/// Transcriber.
@MainActor
final class FrontmostAppTracker {
    private(set) var lastExternalApp: NSRunningApplication?

    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Frontmost")

    init() {
        note(NSWorkspace.shared.frontmostApplication)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main) { [weak self] notification in
                let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                Task { @MainActor [weak self] in
                    self?.note(app)
                }
            }
    }

    private func note(_ app: NSRunningApplication?) {
        guard let app, app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        lastExternalApp = app
    }
}

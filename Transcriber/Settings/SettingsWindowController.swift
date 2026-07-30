//
//  SettingsWindowController.swift
//  Transcriber
//

import AppKit
import SwiftUI

/// AppKit-hosted settings window. The app has no SwiftUI scenes (menu-bar
/// only), so the standard `Settings` scene machinery isn't available.
@MainActor
final class SettingsWindowController: NSWindowController {
    convenience init(rebinder: ShortcutRebinder,
                     onOpenHistory: @escaping () -> Void,
                     historyAdmin: HistoryAdmin) {
        let hosting = NSHostingController(rootView: SettingsView(rebinder: rebinder,
                                                                onOpenHistory: onOpenHistory,
                                                                historyAdmin: historyAdmin))
        let window = NSWindow(contentViewController: hosting)
        window.title = "Transcriber Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
    }

    func show() {
        // LSUIElement apps aren't active by default; activate so the window gets key.
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

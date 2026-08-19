//
//  FloatingPanel.swift
//  Transcriber
//

import AppKit
import SwiftUI

/// Non-activating floating panel. Must NEVER become key or main: if it steals
/// focus, the user's target text field loses focus and direct insertion breaks.
final class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        isMovableByWindowBackground = true
    }

    /// Drag the panel from anywhere on its surface.
    ///
    /// `isMovableByWindowBackground` alone isn't enough: the panel is borderless
    /// and its entire surface is an `NSHostingView`, which swallows the
    /// mouse-down that background dragging relies on. Intercepting the event
    /// here — before it reaches the content — makes the whole panel a drag
    /// handle. Nothing is lost today because the panel has no clickable
    /// controls; scroll events are untouched, so the transcript still scrolls.
    /// **If a button is ever added to the panel, this has to hit-test first.**
    ///
    /// `performDrag` doesn't activate the app, so the user's target text field
    /// stays focused and insertion still works.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, isMovable {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }
}

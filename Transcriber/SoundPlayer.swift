//
//  SoundPlayer.swift
//  Transcriber
//

import AppKit

/// Recording start/stop feedback sounds (system sounds, gated by preference).
@MainActor
enum SoundPlayer {
    static func playStart() {
        play("Tink")
    }

    static func playStop() {
        play("Pop")
    }

    private static func play(_ name: String) {
        guard Preferences.shared.playsSounds else { return }
        NSSound(named: name)?.play()
    }
}

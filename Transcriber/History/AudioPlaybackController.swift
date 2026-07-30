//
//  AudioPlaybackController.swift
//  Transcriber
//

import AVFoundation
import Observation
import os

/// Plays back one retained recording. Deliberately `AVAudioPlayer` rather than
/// an `AVAudioEngine`: nothing here touches the input device, so playback can't
/// disturb the audio route the way capture does.
@MainActor
@Observable
final class AudioPlaybackController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    /// Set when the file named on the entry isn't there any more.
    private(set) var isUnavailable = false

    var rate: Float = 1 {
        didSet {
            player?.rate = rate
            // `play()` restarts at 1× unless the rate is re-applied while playing.
            if isPlaying {
                player?.rate = rate
            }
        }
    }

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Playback")

    /// Points the player at a recording, or marks it unavailable. Safe to call
    /// repeatedly as the selection changes.
    func load(filename: String?) {
        stop()
        guard let filename else {
            isUnavailable = false
            duration = 0
            return
        }
        let url = RecordingsDirectory.url(for: filename)
        guard FileManager.default.fileExists(atPath: url.path) else {
            isUnavailable = true
            duration = 0
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.enableRate = true
            player.rate = rate
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            isUnavailable = false
        } catch {
            logger.error("Could not open \(filename, privacy: .public): \(error.localizedDescription, privacy: .public)")
            isUnavailable = true
            duration = 0
        }
    }

    func togglePlayback() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let player else { return }
        // Starting from the very end would play nothing; wrap to the beginning.
        if player.currentTime >= player.duration - 0.05 {
            player.currentTime = 0
        }
        player.rate = rate
        guard player.play() else { return }
        isPlaying = true
        startTicking()
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTicking()
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func stop() {
        stopTicking()
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
    }

    private func startTicking() {
        stopTicking()
        // 10×/s is enough for a scrubber and a highlighted sentence.
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.tick()
            }
        }
    }

    private func tick() {
        guard let player else { return }
        currentTime = player.currentTime
        if !player.isPlaying {
            isPlaying = false
            stopTicking()
        }
    }

    private func stopTicking() {
        ticker?.invalidate()
        ticker = nil
    }
}

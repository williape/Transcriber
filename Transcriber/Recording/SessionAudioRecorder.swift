//
//  SessionAudioRecorder.swift
//  Transcriber
//

import AVFoundation
import Foundation
import os

/// Writes one dictation's audio to an AAC `.m4a`, fed from the microphone tap.
///
/// The buffers it receives are the ones already converted for the analyzer, so
/// the recording is exactly what was transcribed and its timeline is
/// sample-aligned with the `CMTimeRange`s in the results — no second converter,
/// no extra work on the render thread.
///
/// `append(_:)` is called from the audio render thread and must not block: it
/// hands the buffer to a private serial queue that owns the file and returns.
///
/// Explicitly `nonisolated` — this target defaults to `@MainActor` isolation,
/// which would be exactly wrong for a type the audio thread calls into.
/// `@unchecked Sendable` because every piece of mutable state is confined to
/// `queue`; that confinement is the invariant to preserve when editing this.
nonisolated final class SessionAudioRecorder: @unchecked Sendable {
    struct Recorded: Sendable, Equatable {
        let filename: String
        let byteCount: Int64
    }

    /// Why a session ended up with no file. `empty` and `failed` are kept apart
    /// on purpose: a silent dictation is normal and says nothing to the user,
    /// while a failed write means their audio is being lost and they should hear
    /// about it.
    enum Outcome: Sendable, Equatable {
        case recorded(Recorded)
        case empty
        case failed
    }

    /// `AVAudioPCMBuffer` isn't `Sendable`, but the hand-off here is strictly
    /// one-way: `MicrophoneCapture` allocates a fresh buffer per tap callback and
    /// never touches it again.
    private struct BufferBox: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    let filename: String

    private let url: URL
    private let expectedFormat: AVAudioFormat
    private let queue = DispatchQueue(label: "com.pwilliams.Transcriber.audio-writer", qos: .utility)
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Recorder")

    /// Queue-confined state. Nothing else may touch these.
    private var file: AVAudioFile?
    private var framesWritten: AVAudioFramePosition = 0
    private var failed = false

    /// Opens the file. Throws before any audio starts flowing if the folder or
    /// the encoder won't cooperate, so the caller can carry on without audio.
    init(format: AVAudioFormat, startedAt date: Date = Date()) throws {
        let directory = try RecordingsDirectory.ensureDirectory()
        filename = try RecordingsDirectory.reserveFilename(for: date, in: directory)
        url = directory.appending(path: filename, directoryHint: .notDirectory)
        expectedFormat = format

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVEncoderBitRateKey: 24_000,
        ]
        // `commonFormat`/`interleaved` come from the incoming buffers, not from a
        // guess: `write(from:)` raises an Objective-C exception — uncatchable
        // from Swift — if a buffer's format doesn't match `processingFormat`.
        do {
            file = try AVAudioFile(forWriting: url,
                                   settings: settings,
                                   commonFormat: format.commonFormat,
                                   interleaved: format.isInterleaved)
        } catch {
            // Don't leave the reserved placeholder behind as an orphan.
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        logger.info("Recording to \(self.filename, privacy: .public)")
    }

    /// Called on the audio render thread.
    func append(_ buffer: AVAudioPCMBuffer) {
        // Safe to hand over without copying: `MicrophoneCapture` allocates a
        // fresh converted buffer per tap callback rather than recycling one.
        let box = BufferBox(buffer: buffer)
        queue.async { [weak self] in
            self?.write(box.buffer)
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !failed, let file else { return }
        // Belt and braces against the uncatchable exception described above.
        guard buffer.format == file.processingFormat else {
            logger.error("Buffer format changed mid-session; abandoning the recording")
            failed = true
            return
        }
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // Disk full, encoder failure — never propagated to the user's
            // dictation, which carries on regardless.
            logger.error("Audio write failed: \(error.localizedDescription, privacy: .public)")
            failed = true
        }
    }

    /// Closes the file and reports what happened. Anything but `.recorded`
    /// removes the file.
    func finish() async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.async {
                // Releasing the file closes it, which is what writes the MPEG-4
                // `moov` atom — without this the .m4a is unplayable.
                self.file = nil
                if self.failed {
                    self.removeFile()
                    continuation.resume(returning: .failed)
                    return
                }
                guard self.framesWritten > 0 else {
                    self.removeFile()
                    continuation.resume(returning: .empty)
                    return
                }
                let size = (try? FileManager.default.attributesOfItem(atPath: self.url.path)[.size]) as? Int64
                guard let size, size > 0 else {
                    // Frames went in but nothing came out — that's a failure, not
                    // a silent session.
                    self.logger.error("Recording closed with no data on disk")
                    self.removeFile()
                    continuation.resume(returning: .failed)
                    return
                }
                self.logger.info("Recorded \(self.filename, privacy: .public) (\(size) bytes)")
                continuation.resume(returning: .recorded(Recorded(filename: self.filename, byteCount: size)))
            }
        }
    }

    /// Abandons the recording and deletes the file — cancelled or silent sessions.
    func discard() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.file = nil
                self.removeFile()
                continuation.resume()
            }
        }
    }

    private func removeFile() {
        try? FileManager.default.removeItem(at: url)
    }
}

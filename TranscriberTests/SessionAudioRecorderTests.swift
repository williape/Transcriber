//
//  SessionAudioRecorderTests.swift
//  TranscriberTests
//

import AVFoundation
import Foundation
import Testing
@testable import Transcriber

/// These write into the real recordings folder (the recorder owns its own
/// location), so each test cleans up the file it made.
struct SessionAudioRecorderTests {

    /// The analyzer's format for speech: mono Float32 at 16 kHz.
    private func format() throws -> AVAudioFormat {
        try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000,
                                   channels: 1,
                                   interleaved: false))
    }

    /// A buffer of quiet-but-not-silent audio, so the encoder has something real.
    private func buffer(_ format: AVAudioFormat, frames: AVAudioFrameCount = 4096) throws -> AVAudioPCMBuffer {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try #require(buffer.floatChannelData)
        for frame in 0..<Int(frames) {
            samples[0][frame] = sin(Float(frame) * 0.01) * 0.25
        }
        return buffer
    }

    @Test func writesAPlayableFileOfRoughlyTheRightLength() async throws {
        let format = try format()
        let recorder = try SessionAudioRecorder(format: format)
        defer { RecordingsDirectory.delete(filename: recorder.filename) }

        // 10 × 4096 frames at 16 kHz ≈ 2.56 s.
        for _ in 0..<10 {
            recorder.append(try buffer(format))
        }
        guard case .recorded(let recorded) = await recorder.finish() else {
            Issue.record("Expected a recording")
            return
        }

        #expect(recorded.filename == recorder.filename)
        #expect(recorded.byteCount > 0)

        let url = RecordingsDirectory.url(for: recorded.filename)
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        // AAC pads to frame boundaries, so allow a little slack either side.
        #expect(abs(duration - 2.56) < 0.2)
    }

    @Test func filenameIsTimestampedNotAUUID() throws {
        let recorder = try SessionAudioRecorder(format: try format())
        defer { RecordingsDirectory.delete(filename: recorder.filename) }

        // "2026-07-30 10-45-12.m4a"
        let startsWithAYear = recorder.filename.prefix(4).allSatisfy(\.isNumber)

        #expect(recorder.filename.hasSuffix(".m4a"))
        #expect(startsWithAYear)
        #expect(recorder.filename.contains(" "))
        #expect(UUID(uuidString: String(recorder.filename.dropLast(4))) == nil)
    }

    /// A session with no audio shouldn't leave a stub file behind — and reports
    /// `.empty`, not `.failed`: a silent dictation isn't worth warning about.
    @Test func emptyRecordingIsDiscarded() async throws {
        let recorder = try SessionAudioRecorder(format: try format())

        let outcome = await recorder.finish()

        #expect(outcome == .empty)
        #expect(FileManager.default.fileExists(
            atPath: RecordingsDirectory.url(for: recorder.filename).path) == false)
    }

    /// A buffer whose format doesn't match the file would raise an uncatchable
    /// Objective-C exception inside `write(from:)`, so the recorder refuses it
    /// and reports failure — which is what surfaces the "couldn't save audio"
    /// warning rather than losing the recording silently.
    @Test func mismatchedBufferFormatFailsLoudly() async throws {
        let recorder = try SessionAudioRecorder(format: try format())
        let wrongFormat = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                    sampleRate: 44_100,
                                                    channels: 2,
                                                    interleaved: false))

        recorder.append(try buffer(wrongFormat))
        let outcome = await recorder.finish()

        #expect(outcome == .failed)
        #expect(FileManager.default.fileExists(
            atPath: RecordingsDirectory.url(for: recorder.filename).path) == false)
    }

    /// Cancelled dictation: the file must go, not linger as an orphan.
    @Test func discardRemovesTheFile() async throws {
        let format = try format()
        let recorder = try SessionAudioRecorder(format: format)
        recorder.append(try buffer(format))

        await recorder.discard()

        #expect(FileManager.default.fileExists(
            atPath: RecordingsDirectory.url(for: recorder.filename).path) == false)
    }

    /// Two recorders opened in the same second must not share a file.
    @Test func concurrentSessionsGetDistinctFiles() async throws {
        let format = try format()
        let first = try SessionAudioRecorder(format: format, startedAt: Date())
        let second = try SessionAudioRecorder(format: format, startedAt: Date())
        defer {
            RecordingsDirectory.delete(filename: first.filename)
            RecordingsDirectory.delete(filename: second.filename)
        }

        #expect(first.filename != second.filename)

        await first.discard()
        await second.discard()
    }
}

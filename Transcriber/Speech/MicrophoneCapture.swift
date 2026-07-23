//
//  MicrophoneCapture.swift
//  Transcriber
//

import AVFoundation
import os

/// AVAudioEngine microphone tap, converted to the analyzer's preferred format.
/// `onBuffer` runs on the audio render thread.
final class MicrophoneCapture {
    enum CaptureError: LocalizedError {
        case converterUnavailable

        var errorDescription: String? {
            "The microphone's audio format can't be converted for transcription."
        }
    }

    private let engine = AVAudioEngine()
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Microphone")

    func start(targetFormat: AVAudioFormat,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        // Format mismatch is the classic source of silent failures — always log both.
        logger.info("Mic native: \(nativeFormat, privacy: .public); analyzer: \(targetFormat, privacy: .public)")

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }

        let logger = self.logger
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
            let ratio = targetFormat.sampleRate / nativeFormat.sampleRate
            let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
                return
            }
            var consumed = false
            var conversionError: NSError?
            let status = converter.convert(to: converted, error: &conversionError) { _, inputStatus in
                if consumed {
                    inputStatus.pointee = .noDataNow
                    return nil
                }
                consumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                logger.error("Audio conversion failed: \(conversionError?.localizedDescription ?? "unknown", privacy: .public)")
                return
            }
            if converted.frameLength > 0 {
                onBuffer(converted)
            }
        }

        engine.prepare()
        try engine.start()
        logger.info("Microphone capture started")
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        logger.info("Microphone capture stopped")
    }
}

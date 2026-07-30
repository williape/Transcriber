//
//  MicrophoneCapture.swift
//  Transcriber
//

import AVFoundation
import Accelerate
import os

/// AVAudioEngine microphone tap, converted to the analyzer's preferred format.
/// `onBuffer` and `onLevel` run on the audio render thread.
final class MicrophoneCapture {
    enum CaptureError: LocalizedError {
        case converterUnavailable
        case microphoneUnavailable
        case engineStartFailed(any Error)

        var errorDescription: String? {
            switch self {
            case .converterUnavailable:
                return "The microphone's audio format can't be converted for transcription."
            case .microphoneUnavailable:
                return "No microphone input is available. It may be in use by another app, or no input device is connected."
            case .engineStartFailed(let error):
                return "The microphone couldn't be started — it may be in use by another app. (\(error.localizedDescription))"
            }
        }
    }

    /// Created per session and released in `stop()`. It must **not** be a
    /// long-lived property: an `AVAudioEngine` that has ever touched its
    /// `inputNode` holds the input device open for as long as it exists, which
    /// (a) pins a Bluetooth headset in narrowband HFP mode, wrecking A2DP
    /// playback quality for every other app until Transcriber quits, and
    /// (b) leaves the orange microphone-in-use indicator lit after dictation.
    private var engine: AVAudioEngine?
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Microphone")

    func start(targetFormat: AVAudioFormat,
               onLevel: @escaping @Sendable (Double) -> Void,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        // A previous session's engine should already be gone; be sure, so two
        // engines never hold the device at once.
        stop()
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let nativeFormat = input.outputFormat(forBus: 0)
        // A dead input (in use elsewhere / nothing connected) reports a zero format.
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            self.engine = nil
            throw CaptureError.microphoneUnavailable
        }
        // Format mismatch is the classic source of silent failures — always log both.
        logger.info("Mic native: \(nativeFormat, privacy: .public); analyzer: \(targetFormat, privacy: .public)")

        guard let converter = AVAudioConverter(from: nativeFormat, to: targetFormat) else {
            self.engine = nil
            throw CaptureError.converterUnavailable
        }

        let logger = self.logger
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { buffer, _ in
            if let level = Self.normalizedLevel(of: buffer) {
                onLevel(level)
            }
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
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            self.engine = nil
            throw CaptureError.engineStartFailed(error)
        }
        logger.info("Microphone capture started")
    }

    /// RMS of the first channel mapped from dBFS onto 0...1 (-50 dB floor).
    private static func normalizedLevel(of buffer: AVAudioPCMBuffer) -> Double? {
        guard let channelData = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        var rms: Float = 0
        vDSP_rmsqv(channelData[0], 1, &rms, vDSP_Length(buffer.frameLength))
        let decibels = 20 * log10(max(rms, .leastNormalMagnitude))
        return max(0, min(1, (Double(decibels) + 50) / 50))
    }

    /// Tears the engine down completely rather than just stopping it — see the
    /// note on `engine`. Safe to call repeatedly, and on a session that never
    /// started.
    func stop() {
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        logger.info("Microphone capture stopped; input device released")
    }
}

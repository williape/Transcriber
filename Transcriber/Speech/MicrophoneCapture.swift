//
//  MicrophoneCapture.swift
//  Transcriber
//

import AVFoundation
import Accelerate
import os

/// AVAudioEngine microphone tap, converted to the analyzer's preferred format.
/// `onBuffer` and `onLevel` run on the audio render thread.
///
/// Capture is deliberately not left to the engine's implicit choice of input
/// device. `AVAudioEngine` grabs whatever the system default input happens to be
/// when `inputNode` is first touched, and a device it can't open reports back as
/// a zero-channel format with no further detail. While a conferencing app holds
/// a call that default can be a virtual driver with no input streams at all, so
/// this binds the engine to a device chosen from `AudioInputDevices` and works
/// down the list when one won't start.
@MainActor
final class MicrophoneCapture {
    /// One device's turn at being the input, and how it went. Kept for the error
    /// message: "the microphone is busy" is not much help when the real answer
    /// is that the default input was Zoom's virtual driver.
    struct Attempt: Equatable {
        let device: String
        let reason: String
    }

    enum CaptureError: LocalizedError {
        /// Nothing on the machine presents an input channel.
        case noInputDevice
        /// Every candidate was tried and none of them started.
        case allInputsFailed([Attempt])

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No microphone input is available. No input device is connected, or the connected ones offer no input channels."
            case .allInputsFailed(let attempts):
                let detail = attempts.map { "• \($0.device) — \($0.reason)" }.joined(separator: "\n")
                return """
                The microphone couldn't be started — it may be in use by another app.

                \(detail)
                """
            }
        }
    }

    /// What `start()` was asked to do, kept so capture can be rebuilt on the
    /// same terms when the audio device changes underneath a running session.
    private struct Request {
        let targetFormat: AVAudioFormat
        let includeSystemAudio: Bool
        let onLevel: @Sendable (Double) -> Void
        let onBuffer: @Sendable (AVAudioPCMBuffer) -> Void
    }

    /// Created per session and released in `stop()`. It must **not** be a
    /// long-lived property: an `AVAudioEngine` that has ever touched its
    /// `inputNode` holds the input device open for as long as it exists, which
    /// (a) pins a Bluetooth headset in narrowband HFP mode, wrecking A2DP
    /// playback quality for every other app until Transcriber quits, and
    /// (b) leaves the orange microphone-in-use indicator lit after dictation.
    private var engine: AVAudioEngine?
    /// Non-nil exactly while a session is meant to be capturing.
    private var request: Request?
    private var configurationObserver: (any NSObjectProtocol)?
    /// What the live engine was bound to and tapped with, so a configuration
    /// change can be checked against it rather than taken on trust.
    private var boundDeviceID: AudioDeviceID?
    private var tappedFormat: AVAudioFormat?
    /// The session's private mic + system audio aggregate, when one was asked
    /// for and could be built. Same lifetime rule as `engine`, and released
    /// after it.
    private var systemAudioTap: SystemAudioTap?
    /// Set when system audio was asked for but capture had to fall back to the
    /// microphone alone, so the caller can say so.
    private(set) var systemAudioUnavailable = false
    /// When recent rebuilds happened — the backstop against a rebuild loop.
    private var recentRebuilds: [Date] = []
    private static let maxRebuilds = 3
    private static let rebuildWindow: TimeInterval = 5
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "Microphone")

    func start(targetFormat: AVAudioFormat,
               includeSystemAudio: Bool = false,
               onLevel: @escaping @Sendable (Double) -> Void,
               onBuffer: @escaping @Sendable (AVAudioPCMBuffer) -> Void) throws {
        // A previous session's engine should already be gone; be sure, so two
        // engines never hold the device at once.
        stop()
        systemAudioUnavailable = false
        let request = Request(targetFormat: targetFormat,
                              includeSystemAudio: includeSystemAudio,
                              onLevel: onLevel,
                              onBuffer: onBuffer)
        try activate(request)
        // Only recorded once capture is actually running, so a failed start
        // leaves nothing behind for the configuration observer to act on.
        self.request = request
        observeConfigurationChanges()
    }

    /// Walks the candidate devices in order and keeps the first that starts.
    private func activate(_ request: Request) throws {
        logger.info("Input devices: \(AudioInputDevices.summary(), privacy: .public)")
        let candidates = AudioInputDevices.captureCandidates()
        guard !candidates.isEmpty else {
            logger.error("No input device presents any input channel")
            throw CaptureError.noInputDevice
        }
        if let preferred = AudioInputDevices.defaultInput(), !preferred.canRecord {
            // The single most useful line in the log for this bug: it says the
            // default input can't record at all, rather than that it's busy.
            logger.error("Default input '\(preferred.name, privacy: .public)' presents no input channels — falling back")
        }

        var attempts: [Attempt] = []
        for candidate in candidates {
            do {
                try attach(to: candidate, request: request)
                logger.info("Microphone capture started on '\(candidate.name, privacy: .public)'")
                return
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("Input '\(candidate.name, privacy: .public)' unusable: \(reason, privacy: .public)")
                attempts.append(Attempt(device: candidate.name, reason: reason))
            }
        }
        throw CaptureError.allInputsFailed(attempts)
    }

    /// Why one particular device didn't work. These never reach the user on
    /// their own — `activate` collects them into `allInputsFailed`.
    private enum AttachFailure: LocalizedError {
        case deviceBindingFailed(any Error)
        case deviceUnreadable
        case channelsUnavailable(OSStatus)
        case converterUnavailable
        case engineStartFailed(any Error)

        var errorDescription: String? {
            switch self {
            case .deviceBindingFailed(let error):
                return "the audio engine wouldn't select it (\(error.localizedDescription))"
            case .deviceUnreadable:
                return "it reported no usable audio format"
            case .channelsUnavailable(let status):
                return "its system audio channel couldn't be opened (\(SystemAudioTap.describe(status)))"
            case .converterUnavailable:
                return "its audio format can't be converted for transcription"
            case .engineStartFailed(let error):
                return "the audio engine wouldn't start (\(error.localizedDescription))"
            }
        }
    }

    /// Binds to `device`, or — when system audio is wanted — to a private
    /// aggregate of `device` plus a system audio tap. If the aggregate can't be
    /// built or won't start, the session carries on with the mic alone rather
    /// than failing: half a transcript beats none.
    private func attach(to device: AudioInputDevices.Device, request: Request) throws {
        if request.includeSystemAudio {
            do {
                let tap = try SystemAudioTap(micUID: device.uid)
                systemAudioTap = tap
                try attachEngine(to: tap.aggregateDeviceID, mixingChannels: true, request: request)
                logger.info("Capturing system audio alongside '\(device.name, privacy: .public)'")
                return
            } catch {
                // `attachEngine` has already torn down the tap on its way out.
                teardownEngine()
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                logger.error("System audio unavailable, continuing mic-only: \(reason, privacy: .public)")
                systemAudioUnavailable = true
            }
        }
        try attachEngine(to: device.id, mixingChannels: false, request: request)
    }

    /// `mixingChannels` sums every input channel to mono before conversion —
    /// only for the aggregate, whose channels are mic + system audio. A plain
    /// multi-channel mic is left to `AVAudioConverter` exactly as before.
    private func attachEngine(to deviceID: AudioDeviceID,
                              mixingChannels: Bool,
                              request: Request) throws {
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        // Binding before the format is read is what makes the choice mean
        // anything: the node reports the format of whichever device it is
        // pointed at, and it can only be re-pointed while the engine is stopped.
        do {
            try input.auAudioUnit.setDeviceID(deviceID)
        } catch {
            teardownEngine()
            throw AttachFailure.deviceBindingFailed(error)
        }
        if mixingChannels {
            do {
                try Self.exposeAllInputChannels(of: input)
            } catch {
                teardownEngine()
                throw error
            }
        }

        let nativeFormat = input.outputFormat(forBus: 0)
        // A dead input (in use elsewhere / nothing connected) reports a zero format.
        guard nativeFormat.sampleRate > 0, nativeFormat.channelCount > 0 else {
            teardownEngine()
            throw AttachFailure.deviceUnreadable
        }
        let targetFormat = request.targetFormat
        // Format mismatch is the classic source of silent failures — always log both.
        logger.info("Mic native: \(nativeFormat, privacy: .public); analyzer: \(targetFormat, privacy: .public)")

        let downmix = mixingChannels && nativeFormat.channelCount > 1
        let sourceFormat = downmix ? Self.monoFormat(sampleRate: nativeFormat.sampleRate) : nativeFormat
        guard let sourceFormat, let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            teardownEngine()
            throw AttachFailure.converterUnavailable
        }

        let logger = self.logger
        let onLevel = request.onLevel
        let onBuffer = request.onBuffer
        input.installTap(onBus: 0, bufferSize: 4096, format: nativeFormat) { tapped, _ in
            guard let buffer = downmix ? Self.downmixToMono(tapped) : tapped else { return }
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
            teardownEngine()
            throw AttachFailure.engineStartFailed(error)
        }
        boundDeviceID = deviceID
        tappedFormat = nativeFormat
    }

    /// The engine posts this when its I/O device is replaced or reconfigured —
    /// which is precisely what happens when a conferencing app joins or leaves a
    /// call. The old engine's tap is already dead by then, so rebuilding is the
    /// only way the session survives; doing nothing would leave the panel
    /// recording silence.
    private func observeConfigurationChanges() {
        // `object: nil` on purpose: passing the engine would have CoreFoundation
        // hold it unretained for filtering, and this class is careful never to
        // let a reference to the engine outlive the session. Identity is checked
        // in the handler instead.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil,
            queue: .main) { [weak self] notification in
                let changed = notification.object as? AVAudioEngine
                MainActor.assumeIsolated {
                    self?.handleConfigurationChange(of: changed)
                }
            }
    }

    private func handleConfigurationChange(of changed: AVAudioEngine?) {
        guard let request, let engine, changed === engine else { return }

        // Binding a device and starting the engine make the engine post this
        // notification about *itself*, and it arrives after the new engine is
        // in place. Rebuilding on every one is a feedback loop (seen live:
        // a rebuild every ~140 ms, no audio ever reaching the analyzer). So
        // only act when something really moved under the session.
        let input = engine.inputNode
        let deviceUnchanged = input.auAudioUnit.deviceID == boundDeviceID
        let formatUnchanged = tappedFormat.map { input.outputFormat(forBus: 0) == $0 } ?? false
        if deviceUnchanged && formatUnchanged {
            if engine.isRunning {
                logger.debug("Configuration change with device and format unchanged — ignoring")
                return
            }
            // Same device, same format, just stopped: restarting keeps the
            // existing tap and doesn't re-bind, so it can't feed the loop.
            do {
                try engine.start()
                logger.info("Audio engine stopped by a configuration change — restarted")
                return
            } catch {
                logger.error("Restart after configuration change failed: \(error.localizedDescription, privacy: .public) — rebuilding")
            }
        }

        let now = Date()
        recentRebuilds = recentRebuilds.filter { now.timeIntervalSince($0) < Self.rebuildWindow }
        guard recentRebuilds.count < Self.maxRebuilds else {
            logger.error("Audio device keeps reconfiguring — not rebuilding again this session")
            return
        }
        recentRebuilds.append(now)

        logger.info("Audio device reconfigured mid-session — rebuilding capture")
        teardownEngine()
        do {
            try activate(request)
            observeConfigurationChanges()
        } catch {
            // Nothing left to capture on. The session stays alive so whatever
            // was transcribed before the change still reaches the user.
            self.request = nil
            logger.error("Capture could not be restored after the device changed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// AUHAL hands the engine only the aggregate's *first* input stream — the
    /// mic — unless told otherwise: the hardware side presents mic + tap, but
    /// the client format defaults to one channel, so the system audio is
    /// silently dropped (seen in the spike: device 2ch, `inputNode` 1ch). This
    /// widens the client side to every hardware channel, mapped one to one.
    /// Must run after `setDeviceID` and before the node's format is read.
    private static func exposeAllInputChannels(of input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw AttachFailure.channelsUnavailable(kAudioUnitErr_Uninitialized) }
        let inputElement: AudioUnitElement = 1
        var hardware = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input, inputElement, &hardware, &size)
        guard status == noErr else { throw AttachFailure.channelsUnavailable(status) }
        let channels = hardware.mChannelsPerFrame
        guard channels > 1 else { return }

        var map = (0..<Int32(channels)).map { $0 }
        status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_ChannelMap,
                                      kAudioUnitScope_Output, inputElement,
                                      &map, UInt32(map.count * MemoryLayout<Int32>.size))
        guard status == noErr else { throw AttachFailure.channelsUnavailable(status) }

        var client = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, inputElement, &client, &size)
        guard status == noErr else { throw AttachFailure.channelsUnavailable(status) }
        guard client.mChannelsPerFrame != channels else { return }
        // The client format is deinterleaved float, so only the channel count moves.
        client.mChannelsPerFrame = channels
        status = AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                      kAudioUnitScope_Output, inputElement, &client, size)
        guard status == noErr else { throw AttachFailure.channelsUnavailable(status) }
    }

    nonisolated private static func monoFormat(sampleRate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Sums every channel of a deinterleaved float buffer into one, clipped to
    /// ±1. Mic and system audio arrive as separate channels of the aggregate;
    /// the transcriber wants a single stream. Mono input comes back as is;
    /// anything that isn't deinterleaved float yields `nil`.
    nonisolated static func downmixToMono(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channels = Int(buffer.format.channelCount)
        guard channels > 1 else { return buffer }
        guard buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let source = buffer.floatChannelData,
              let format = monoFormat(sampleRate: buffer.format.sampleRate),
              let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: max(buffer.frameLength, 1)),
              let output = mono.floatChannelData?[0] else {
            return nil
        }
        let frames = Int(buffer.frameLength)
        mono.frameLength = buffer.frameLength
        guard frames > 0 else { return mono }
        let length = vDSP_Length(frames)
        output.update(from: source[0], count: frames)
        for channel in 1..<channels {
            vDSP_vadd(output, 1, source[channel], 1, output, 1, length)
        }
        var low: Float = -1
        var high: Float = 1
        vDSP_vclip(output, 1, &low, &high, output, 1, length)
        return mono
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
        request = nil
        recentRebuilds = []
        guard engine != nil || systemAudioTap != nil else { return }
        teardownEngine()
        logger.info("Microphone capture stopped; input device released")
    }

    /// Releases the engine and the observer that was watching it, leaving
    /// `request` alone so a rebuild can still use it.
    private func teardownEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
            self.configurationObserver = nil
        }
        boundDeviceID = nil
        tappedFormat = nil
        releaseEngine()
        // Only once the engine is gone: destroying an aggregate out from under
        // a live engine is a device vanishing mid-I/O.
        systemAudioTap?.destroy()
        systemAudioTap = nil
    }

    /// Separate from `teardownEngine` so the last reference to the engine is
    /// dropped when this returns, before the aggregate it was bound to goes.
    private func releaseEngine() {
        guard let engine else { return }
        self.engine = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
    }
}

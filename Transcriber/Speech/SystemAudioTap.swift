//
//  SystemAudioTap.swift
//  Transcriber
//

import CoreAudio
import Foundation
import os

/// One session's worth of "everything the Mac is playing", presented as part of
/// an input device `AVAudioEngine` can bind to.
///
/// A CoreAudio process tap captures what processes *play*, before it reaches
/// the output device, so the far side of a call is heard whether it's going to
/// headphones, AirPods or speakers. On its own a tap isn't a device, so it's
/// wrapped in a private aggregate together with the session's microphone: the
/// mic is the clock master and the tap is drift-corrected onto it, which means
/// the engine's input node delivers mic and system-audio channels side by side,
/// already in sync.
///
/// Like the engine itself (see `MicrophoneCapture.engine`), this must never
/// outlive the session that created it. Both objects are private, so no other
/// app sees them, and CoreAudio removes them if Transcriber dies — but while
/// the process lives, a leaked aggregate keeps the mic open.
@MainActor
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tapCreationFailed(let status):
                return "the system audio tap couldn't be created (\(SystemAudioTap.describe(status)))"
            case .aggregateCreationFailed(let status):
                return "the combined mic + system audio device couldn't be created (\(SystemAudioTap.describe(status)))"
            }
        }
    }

    /// The device to hand to `AVAudioEngine` in place of the microphone.
    let aggregateDeviceID: AudioDeviceID
    private var tapID: AudioObjectID
    private var destroyed = false
    private let logger = Logger(subsystem: "com.pwilliams.Transcriber", category: "SystemAudio")

    static let aggregateName = "Transcriber System Audio"

    init(micUID: String) throws {
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObjectID().map { [$0] } ?? [])
        // The process object only exists once Transcriber has touched audio, so
        // the bundle ID is what reliably keeps our own start/stop chimes out.
        if let bundleID = Bundle.main.bundleIdentifier {
            description.bundleIDs = [bundleID]
        }
        description.name = "Transcriber system audio tap"
        description.isPrivate = true
        // Unmuted: the user still has to hear the call.
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(description, &tapID)
        guard tapStatus == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw TapError.tapCreationFailed(tapStatus)
        }
        self.tapID = tapID

        let composition: [String: Any] = [
            kAudioAggregateDeviceNameKey: Self.aggregateName,
            kAudioAggregateDeviceUIDKey: "com.pwilliams.Transcriber.SystemAudio.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: micUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // Not `tapautostart`: that holds the device's start until some app
            // plays audio, which would leave the mic dead in a quiet room.
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: micUID],
            ],
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: description.uuid.uuidString,
                 kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        var aggregateID = AudioDeviceID(kAudioObjectUnknown)
        let aggregateStatus = AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID)
        guard aggregateStatus == noErr, aggregateID != AudioDeviceID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(tapID)
            throw TapError.aggregateCreationFailed(aggregateStatus)
        }
        aggregateDeviceID = aggregateID

        logger.info("System audio tap \(tapID) (\(Self.tapFormat(tapID), privacy: .public)) aggregated with mic '\(micUID, privacy: .public)' as device \(aggregateID)")
    }

    /// Removes the aggregate, then the tap it reads from. Idempotent. The
    /// engine bound to the aggregate must already be gone.
    func destroy() {
        guard !destroyed else { return }
        destroyed = true
        let aggregateStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        let tapStatus = AudioHardwareDestroyProcessTap(tapID)
        if aggregateStatus != noErr || tapStatus != noErr {
            logger.error("System audio teardown: aggregate \(Self.describe(aggregateStatus), privacy: .public), tap \(Self.describe(tapStatus), privacy: .public)")
        } else {
            logger.info("System audio tap and aggregate destroyed")
        }
    }

    /// Transcriber's own CoreAudio process object, or `nil` if it has none yet
    /// (it appears once the process first does audio I/O).
    static func ownProcessObjectID() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var pid = getpid()
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid,
                                                &size, &objectID)
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    private static func tapFormat(_ tapID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format) == noErr else {
            return "format unknown"
        }
        return "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame)ch"
    }

    /// OSStatus values from the HAL are usually four-character codes.
    nonisolated static func describe(_ status: OSStatus) -> String {
        let bytes = withUnsafeBytes(of: UInt32(bitPattern: status).bigEndian) { Array($0) }
        if bytes.allSatisfy({ (0x20...0x7E).contains($0) }) {
            return "'\(String(decoding: bytes, as: UTF8.self))'"
        }
        return "\(status)"
    }
}

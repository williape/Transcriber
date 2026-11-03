//
//  AudioInputDevices.swift
//  Transcriber
//

import CoreAudio
import Foundation

/// CoreAudio's view of the machine's input devices.
///
/// `AVAudioEngine` binds its input node to whatever the system default input is
/// at the moment the node is first touched, and reports any failure to open it
/// as nothing more than a zero-channel format — no device name, no status code.
/// That opacity is the whole story behind "Transcriber hears nothing while I'm
/// on a call": conferencing apps ship virtual audio drivers (`ZoomAudioDevice`,
/// `Microsoft Teams Audio`) and move the default input around when a call starts
/// and ends, and a device presenting no input streams is indistinguishable, from
/// the engine's side, from a device that's simply busy.
///
/// Enumerating the devices ourselves lets `MicrophoneCapture` name the device it
/// tried, say why it didn't work, and go on to the next one.
enum AudioInputDevices {
    struct Device: Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        /// Channels summed across the device's input streams. Zero means it
        /// can't record, whatever its name suggests.
        let inputChannelCount: UInt32

        var canRecord: Bool { inputChannelCount > 0 }
    }

    /// The system default input, whether or not it can actually record — a
    /// default that presents no input channels is exactly the case worth
    /// reporting, so it isn't filtered out here.
    static func defaultInput() -> Device? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &deviceID)
        guard status == noErr, deviceID != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        return describe(deviceID)
    }

    /// Every device presenting at least one input channel, in CoreAudio's order.
    static func recordingCapable() -> [Device] {
        allDeviceIDs().map(describe).filter(\.canRecord)
    }

    /// Devices to try, best first: the default input, then every other device
    /// that could stand in for it. Ordering matters — falling back to another
    /// microphone is better than failing outright, but only after the one the
    /// user actually chose has had its turn.
    static func captureCandidates() -> [Device] {
        order(preferred: defaultInput(), available: recordingCapable())
    }

    /// The ordering rule on its own, away from CoreAudio so it can be tested:
    /// a default input that can record leads, anything else that can record
    /// follows, and a default that can't record is dropped rather than tried.
    static func order(preferred: Device?, available: [Device]) -> [Device] {
        let usable = available.filter(\.canRecord)
        guard let preferred, preferred.canRecord else { return usable }
        return [preferred] + usable.filter { $0.id != preferred.id }
    }

    /// One-line inventory for the log — the first thing worth knowing when a
    /// session fails to start on someone else's machine.
    static func summary() -> String {
        let devices = allDeviceIDs().map(describe).filter { $0.canRecord || $0.id == defaultInput()?.id }
        guard !devices.isEmpty else { return "none" }
        let defaultID = defaultInput()?.id
        return devices.map { device in
            let marker = device.id == defaultID ? "*" : ""
            return "\(marker)\(device.name) [\(device.inputChannelCount)ch]"
        }.joined(separator: ", ")
    }

    static func describe(_ id: AudioDeviceID) -> Device {
        Device(id: id,
               uid: string(id, selector: kAudioDevicePropertyDeviceUID) ?? "",
               name: string(id, selector: kAudioObjectPropertyName) ?? "Unknown device",
               inputChannelCount: inputChannelCount(id))
    }

    // MARK: - CoreAudio property reads

    private static func allDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        var ids = [AudioDeviceID](repeating: AudioDeviceID(kAudioObjectUnknown),
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    /// Sums `kAudioDevicePropertyStreamConfiguration` over the input scope. The
    /// buffer list is variable-length, so it has to be read into raw memory
    /// sized by CoreAudio rather than a fixed `AudioBufferList`.
    private static func inputChannelCount(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return 0
        }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                       alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, storage) == noErr else {
            return 0
        }
        let buffers = UnsafeMutableAudioBufferListPointer(
            storage.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.reduce(0) { $0 + $1.mNumberChannels }
    }

    /// `Unmanaged` rather than a bare `CFString`: CoreAudio hands these back
    /// +1 retained, and taking them unmanaged is what balances that.
    private static func string(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else {
            return nil
        }
        return string as String
    }
}

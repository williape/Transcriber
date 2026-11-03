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
        /// `kAudioDevicePropertyTransportType` — built-in, USB, Bluetooth, …
        var transportType: UInt32 = 0

        var canRecord: Bool { inputChannelCount > 0 }
        /// An aggregate is never "the microphone": macOS's own
        /// `CADefaultDeviceAggregate-<pid>` and Transcriber's private system
        /// audio aggregate both show up in the device list, and binding to
        /// either as the mic would wrap an aggregate in an aggregate.
        var isAggregate: Bool { transportType == kAudioDeviceTransportTypeAggregate }
        /// What capture may bind to.
        var isCaptureCandidate: Bool { canRecord && !isAggregate }
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
    /// Aggregates are dropped wherever they appear.
    static func order(preferred: Device?, available: [Device]) -> [Device] {
        let usable = available.filter(\.isCaptureCandidate)
        guard let preferred, preferred.isCaptureCandidate else { return usable }
        return [preferred] + usable.filter { $0.id != preferred.id }
    }

    /// One-line inventory for the log — the first thing worth knowing when a
    /// session fails to start on someone else's machine.
    static func summary() -> String {
        let devices = allDeviceIDs().map(describe).filter {
            $0.isCaptureCandidate || $0.id == defaultInput()?.id
        }
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
               inputChannelCount: inputChannelCount(id),
               transportType: uint32(id, selector: kAudioDevicePropertyTransportType) ?? 0)
    }

    /// Whether the default output is the Mac's own speakers — the case where
    /// the mic also hears the far side of a call, so system audio capture
    /// would transcribe it twice. Headphones on the built-in jack share the
    /// built-in transport, so the data source tells them apart where it can.
    static func defaultOutputIsBuiltInSpeakers() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != AudioDeviceID(kAudioObjectUnknown),
              uint32(deviceID, selector: kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn else {
            return false
        }
        if let source = uint32(deviceID, selector: kAudioDevicePropertyDataSource, scope: kAudioObjectPropertyScopeOutput) {
            return source == internalSpeakerSource
        }
        let name = string(deviceID, selector: kAudioObjectPropertyName) ?? ""
        return !name.localizedCaseInsensitiveContains("headphone")
    }

    /// `'ispk'`, the built-in output's internal-speaker data source.
    private static let internalSpeakerSource: UInt32 = 0x6973_706B

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

    private static func uint32(_ id: AudioObjectID,
                               selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
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

/// Calls `onChange` on the main queue whenever the system default output
/// device changes — headphones unplugged, AirPods connected — until `stop()`
/// or deinit. Lets a running system audio session warn about speakers when the
/// switch happens mid-call, not only at start.
@MainActor
final class DefaultOutputObserver {
    private var listener: AudioObjectPropertyListenerBlock?
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    init(onChange: @escaping @MainActor () -> Void) {
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            MainActor.assumeIsolated { onChange() }
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, .main, block) == noErr {
            listener = block
        }
    }

    func stop() {
        guard let listener else { return }
        self.listener = nil
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                               &address, .main, listener)
    }

    isolated deinit {
        stop()
    }
}

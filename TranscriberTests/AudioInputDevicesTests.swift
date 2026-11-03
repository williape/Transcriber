//
//  AudioInputDevicesTests.swift
//  TranscriberTests
//

import CoreAudio
import Foundation
import Testing
@testable import Transcriber

struct AudioInputDevicesTests {

    private func device(_ id: AudioDeviceID,
                        name: String,
                        inputChannels: UInt32 = 1) -> AudioInputDevices.Device {
        AudioInputDevices.Device(id: id,
                                 uid: "uid-\(id)",
                                 name: name,
                                 inputChannelCount: inputChannels)
    }

    @Test func defaultInputLeadsAndIsNotRepeated() {
        let builtIn = device(1, name: "MacBook Pro Microphone")
        let headset = device(2, name: "AirPods Pro")
        let order = AudioInputDevices.order(preferred: headset, available: [builtIn, headset])
        #expect(order == [headset, builtIn])
    }

    /// The Zoom/Teams case: their virtual drivers can become the default input
    /// while presenting no input streams. Trying that device is what produced
    /// "no microphone available" mid-call, so it must be skipped, not led with.
    @Test func defaultThatCannotRecordIsSkipped() {
        let virtualDriver = device(9, name: "ZoomAudioDevice", inputChannels: 0)
        let builtIn = device(1, name: "MacBook Pro Microphone")
        let order = AudioInputDevices.order(preferred: virtualDriver, available: [builtIn])
        #expect(order == [builtIn])
    }

    @Test func devicesWithoutInputChannelsAreNeverCandidates() {
        let speakers = device(3, name: "External Headphones", inputChannels: 0)
        let builtIn = device(1, name: "MacBook Pro Microphone")
        let order = AudioInputDevices.order(preferred: builtIn, available: [builtIn, speakers])
        #expect(order == [builtIn])
    }

    @Test func noDefaultStillOffersEveryUsableInput() {
        let builtIn = device(1, name: "MacBook Pro Microphone")
        let usb = device(4, name: "Yeti", inputChannels: 2)
        let order = AudioInputDevices.order(preferred: nil, available: [builtIn, usb])
        #expect(order == [builtIn, usb])
    }

    @Test func nothingUsableYieldsNoCandidates() {
        let speakers = device(3, name: "External Headphones", inputChannels: 0)
        #expect(AudioInputDevices.order(preferred: nil, available: [speakers]).isEmpty)
    }

    /// macOS's `CADefaultDeviceAggregate-<pid>` and our own private system
    /// audio aggregate both present input channels; neither is a microphone.
    @Test func aggregatesAreNeverCandidates() {
        let builtIn = device(1, name: "MacBook Pro Microphone")
        var aggregate = device(7, name: "CADefaultDeviceAggregate-123", inputChannels: 2)
        aggregate.transportType = kAudioDeviceTransportTypeAggregate
        #expect(AudioInputDevices.order(preferred: builtIn, available: [aggregate, builtIn]) == [builtIn])
        #expect(AudioInputDevices.order(preferred: aggregate, available: [aggregate, builtIn]) == [builtIn])
    }
}

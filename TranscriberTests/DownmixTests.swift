//
//  DownmixTests.swift
//  TranscriberTests
//

import AVFoundation
import Testing
@testable import Transcriber

struct DownmixTests {

    private func buffer(_ channels: [[Float]], sampleRate: Double = 48_000) -> AVAudioPCMBuffer {
        // More than two channels needs an explicit layout — the same discrete
        // layout an aggregate of mic + tap channels presents.
        let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels.count))!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                   interleaved: false, channelLayout: layout)
        let frames = channels[0].count
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        for (index, samples) in channels.enumerated() {
            buffer.floatChannelData![index].update(from: samples, count: frames)
        }
        return buffer
    }

    private func samples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }

    @Test func monoPassesThroughUntouched() {
        let mono = buffer([[0.1, -0.2, 0.3]])
        #expect(MicrophoneCapture.downmixToMono(mono) === mono)
    }

    @Test func channelsAreSummed() throws {
        let mixed = try #require(MicrophoneCapture.downmixToMono(buffer([[0.1, -0.2, 0.25], [0.2, 0.1, 0.25]])))
        #expect(mixed.format.channelCount == 1)
        #expect(mixed.format.sampleRate == 48_000)
        let out = samples(mixed)
        #expect(abs(out[0] - 0.3) < 1e-6)
        #expect(abs(out[1] - -0.1) < 1e-6)
        #expect(abs(out[2] - 0.5) < 1e-6)
    }

    @Test func sumIsClippedToFullScale() throws {
        let mixed = try #require(MicrophoneCapture.downmixToMono(buffer([[0.8, -0.9], [0.7, -0.6], [0.1, 0]])))
        #expect(samples(mixed) == [1, -1])
    }

    @Test func emptyBufferStaysEmpty() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let empty = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16)!
        let mixed = try #require(MicrophoneCapture.downmixToMono(empty))
        #expect(mixed.frameLength == 0)
    }
}

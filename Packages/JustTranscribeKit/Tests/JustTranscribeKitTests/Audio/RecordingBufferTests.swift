import Accelerate
import AVFoundation
import Testing
@testable import JustTranscribeKit

struct RecordingBufferTests {
    /// Device-like buffers, stereo 48 kHz by default; mono and stereo carry `samples` on every channel,
    /// wider interfaces on the first channel only.
    private func chunks(
        _ samples: [Float], frames: Int = 4_800, rate: Double = 48_000, channels: AVAudioChannelCount = 2
    ) throws -> [AVAudioPCMBuffer] {
        // Over two channels a format needs a layout; audio interfaces report discrete channels.
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels))
        let format = channels > 2
            ? AVAudioFormat(standardFormatWithSampleRate: rate, channelLayout: layout)
            : try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels))
        return try stride(from: 0, to: samples.count, by: frames).map { start in
            let count = min(frames, samples.count - start)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            for channel in 0..<Int(channels) {
                // An interface carries the mic on its first input; the rest stay silent.
                if channels > 2 && channel > 0 {
                    buffer.floatChannelData![channel].update(repeating: 0, count: count)
                } else {
                    samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress! + start, count: count) }
                }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            return buffer
        }
    }

    /// Built-in mics, USB mics and audio interfaces, headsets in call mode, studio rates.
    @Test(arguments: [(48_000, 2), (44_100, 1), (44_100, 2), (24_000, 1), (16_000, 1), (8_000, 1), (96_000, 4)]
        as [(Double, AVAudioChannelCount)])
    func convertsAnyDeviceFormatTo16kMono(rate: Double, channels: AVAudioChannelCount) throws {
        let buffer = RecordingBuffer()
        for chunk in try chunks(Signals.tone(seconds: 1, rate: Int(rate)), frames: Int(rate / 10), rate: rate, channels: channels) {
            buffer.append(chunk)
        }
        #expect(buffer.level == 1)

        let samples = buffer.finish()
        #expect(abs(samples.count - 16_000) <= 16)
        let rms = samples.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) }
        #expect(abs(20 * log10(rms) + 20) < 0.5)
    }

    @Test func switchingInputFormatKeepsTheTake() throws {
        let buffer = RecordingBuffer()
        for chunk in try chunks(Signals.tone(seconds: 1, rate: 48_000)) {
            buffer.append(chunk)
        }
        // A Bluetooth headset switching to its call profile drops the input to 24 kHz.
        for chunk in try chunks(Signals.tone(seconds: 0.5, rate: 24_000), frames: 2_400, rate: 24_000) {
            buffer.append(chunk)
        }
        #expect(abs(buffer.finish().count - 24_000) <= 32)
    }

    @Test func quietInputHasZeroLevel() throws {
        let buffer = RecordingBuffer()
        for chunk in try chunks(Signals.tone(seconds: 0.2, dbfs: -70, rate: 48_000)) {
            buffer.append(chunk)
        }
        #expect(buffer.level == 0)
    }

    @Test(arguments: [(-80, 0.0), (-55, 0.0), (-47.5, 0.5), (-40, 1.0), (0, 1.0)] as [(Float, Double)])
    func levelMapsDecibels(db: Float, level: Double) {
        #expect(abs(LevelMeter.level(rms: pow(10, db / 20)) - level) < 0.001)
    }
}

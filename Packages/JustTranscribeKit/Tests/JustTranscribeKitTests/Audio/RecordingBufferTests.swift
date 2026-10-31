import Accelerate
import AVFoundation
import Testing
@testable import JustTranscribeKit

struct RecordingBufferTests {
    /// Stereo 48 kHz buffers like a typical input device delivers, both channels carrying `samples`.
    private func chunks(_ samples: [Float], frames: Int = 4_800, rate: Double = 48_000) throws -> [AVAudioPCMBuffer] {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        return try stride(from: 0, to: samples.count, by: frames).map { start in
            let count = min(frames, samples.count - start)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
            for channel in 0..<2 {
                samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress! + start, count: count) }
            }
            buffer.frameLength = AVAudioFrameCount(count)
            return buffer
        }
    }

    @Test func convertsAndAccumulatesTo16kMono() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(RecordingBuffer(inputFormat: format))
        for chunk in try chunks(Signals.tone(seconds: 1, rate: 48_000)) {
            buffer.append(chunk)
        }
        #expect(buffer.level == 1)

        let samples = buffer.finish()
        #expect(abs(samples.count - 16_000) <= 16)
        let rms = samples.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) }
        #expect(abs(20 * log10(rms) + 20) < 0.5)
    }

    @Test func switchingInputFormatKeepsTheTake() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(RecordingBuffer(inputFormat: format))
        for chunk in try chunks(Signals.tone(seconds: 1, rate: 48_000)) {
            buffer.append(chunk)
        }
        // A Bluetooth headset switching to its call profile drops the input to 24 kHz.
        let headset = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 2))
        #expect(buffer.switchInput(to: headset))
        for chunk in try chunks(Signals.tone(seconds: 0.5, rate: 24_000), frames: 2_400, rate: 24_000) {
            buffer.append(chunk)
        }
        #expect(abs(buffer.finish().count - 24_000) <= 32)
    }

    @Test func quietInputHasZeroLevel() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(RecordingBuffer(inputFormat: format))
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

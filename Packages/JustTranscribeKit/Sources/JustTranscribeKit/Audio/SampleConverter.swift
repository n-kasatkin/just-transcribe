import Accelerate
import AVFoundation

/// Streams PCM buffers of any sample rate and channel count into 16 kHz mono Float samples.
/// Not thread-safe; one instance per stream.
final class SampleConverter {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechGate.sampleRate), channels: 1, interleaved: false
    )!

    /// The format this converter accepts.
    let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter
    /// Set for inputs over two channels: AVAudioConverter downmixes discrete channels (audio interfaces)
    /// to silence, so their channels are summed into this mono format first. Summing keeps a single
    /// active mic at full level, where averaging would lower it with every silent channel.
    private let summed: AVAudioFormat?

    init?(from input: AVAudioFormat) {
        if input.channelCount > 2 {
            guard input.commonFormat == .pcmFormatFloat32, !input.isInterleaved,
                  let mono = AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 1)
            else { return nil }
            summed = mono
        } else {
            summed = nil
        }
        guard let converter = AVAudioConverter(from: summed ?? input, to: Self.format) else { return nil }
        converter.downmix = true
        self.converter = converter
        inputFormat = input
    }

    /// The samples `buffer` yields so far; the resampler may hold a few back until the next call.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
        let buffer = try summed.map { try sum(buffer, into: $0) } ?? buffer
        var supplied = false
        return try drain(capacity: buffer.frameLength) { _, status in
            guard !supplied else {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
    }

    private func sum(_ buffer: AVAudioPCMBuffer, into format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        guard let mono = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength),
              let output = mono.floatChannelData?[0], let input = buffer.floatChannelData
        else { throw CocoaError(.featureUnsupported) }
        let frames = Int(buffer.frameLength)
        output.initialize(repeating: 0, count: frames)
        for channel in 0..<Int(buffer.format.channelCount) {
            vDSP_vadd(output, 1, input[channel], 1, output, 1, vDSP_Length(frames))
        }
        mono.frameLength = buffer.frameLength
        return mono
    }

    /// The samples still held by the resampler; the converter is ready for a new stream afterwards.
    func finish() throws -> [Float] {
        defer { converter.reset() }
        return try drain(capacity: 4096) { _, status in
            status.pointee = .endOfStream
            return nil
        }
    }

    private func drain(capacity inputFrames: AVAudioFrameCount, input: AVAudioConverterInputBlock) throws -> [Float] {
        let ratio = Self.format.sampleRate / converter.inputFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(inputFrames) * ratio).rounded(.up)) + 256
        var samples: [Float] = []
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: Self.format, frameCapacity: capacity),
                  let data = output.floatChannelData
            else { throw CocoaError(.featureUnsupported) }
            var error: NSError?
            let status = converter.convert(to: output, error: &error, withInputFrom: input)
            if status == .error { throw error ?? CocoaError(.featureUnsupported) }
            samples.append(contentsOf: UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
            guard status == .haveData else { return samples }
        }
    }
}

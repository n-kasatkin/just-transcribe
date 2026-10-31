import AVFoundation

/// Streams PCM buffers of any format into 16 kHz mono Float samples, downmixing extra channels.
/// Not thread-safe; one instance per stream.
final class SampleConverter {
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: Double(SpeechGate.sampleRate), channels: 1, interleaved: false
    )!

    private let converter: AVAudioConverter

    init?(from input: AVAudioFormat) {
        guard let converter = AVAudioConverter(from: input, to: Self.format) else { return nil }
        converter.downmix = true
        self.converter = converter
    }

    /// The samples `buffer` yields so far; the resampler may hold a few back until the next call.
    func convert(_ buffer: AVAudioPCMBuffer) throws -> [Float] {
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

import AVFoundation

/// The file a take is saved as: AAC .m4a for cloud providers, 16-bit WAV for local engines.
public enum AudioContainer: String, Sendable, CaseIterable {
    case m4a
    case wav

    public var fileExtension: String { rawValue }

    var settings: [String: Any] {
        switch self {
        case .m4a:
            [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: SpeechGate.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 32_000,
            ]
        case .wav:
            [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: SpeechGate.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        }
    }
}

/// Writes 16 kHz mono Float samples to an audio file.
public enum AudioFileWriter {
    /// Writes `samples` to `url`, overwriting it. The file type follows the URL's extension, so
    /// name it with `container.fileExtension`. The file is closed when this returns.
    public static func write(_ samples: [Float], to url: URL, as container: AudioContainer) throws {
        let file = try AVAudioFile(
            forWriting: url, settings: container.settings, commonFormat: .pcmFormatFloat32, interleaved: false
        )
        let chunk = 16_384
        for start in stride(from: 0, to: samples.count, by: chunk) {
            let count = min(chunk, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: SampleConverter.format, frameCapacity: AVAudioFrameCount(count)),
                  let data = buffer.floatChannelData
            else { throw CocoaError(.fileWriteUnknown) }
            samples.withUnsafeBufferPointer { data[0].update(from: $0.baseAddress! + start, count: count) }
            buffer.frameLength = AVAudioFrameCount(count)
            try file.write(from: buffer)
        }
    }
}

import AVFoundation

/// Converts a saved take for engines that need another container.
public enum AudioConverter {
    /// Writes a 16 kHz mono 16-bit WAV beside `source` (same name, `.wav`) and returns its URL.
    /// Retry uses it when the active model is local and the take was saved as m4a.
    public static func wav(from source: URL) throws -> URL {
        let file = try AVAudioFile(forReading: source)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let converter = SampleConverter(from: file.processingFormat)
        else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: source]) }
        try file.read(into: buffer)
        let samples = converter.convert(buffer) + converter.finish()
        let destination = source.deletingPathExtension().appendingPathExtension(AudioContainer.wav.fileExtension)
        try AudioFileWriter.write(samples, to: destination, as: .wav)
        return destination
    }
}

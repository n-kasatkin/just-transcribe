import AVFoundation

/// Readies a saved recording for another `ostt transcribe`.
public enum RetryTake {
    /// Local engines read only WAV, and takes recorded for a cloud model are m4a.
    public static func needsWAVConversion(_ file: URL, for model: ActiveModel) -> Bool {
        model.audioFormat == .wav && file.pathExtension.lowercased() != AudioContainer.wav.fileExtension
    }

    /// The file to send, converted to WAV when the model needs it, and its length for the timeout.
    /// Runs synchronously; call it off the main actor.
    public static func prepare(_ file: URL, for model: ActiveModel) throws -> (file: URL, duration: Duration) {
        if needsWAVConversion(file, for: model) {
            let wav = try AudioConverter.wav(from: file)
            return (wav, try duration(of: wav))
        }
        // ostt CLI takes can be Ogg, which AVAudioFile cannot open; a cloud engine reads them as they are.
        if let duration = try? duration(of: file) { return (file, duration) }
        return (file, try estimatedDuration(of: file))
    }

    /// The duration a file of this size would have at 8 kbps, below the bitrates ostt is set up
    /// with, so the transcribe timeout is never shorter than the audio.
    private static func estimatedDuration(of file: URL) throws -> Duration {
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))
        let bytes = (attributes[.size] as? NSNumber)?.doubleValue ?? 0
        return .seconds(bytes / 1_000)
    }

    private static func duration(of file: URL) throws -> Duration {
        let audio = try AVAudioFile(forReading: file)
        return .seconds(Double(audio.length) / audio.fileFormat.sampleRate)
    }
}

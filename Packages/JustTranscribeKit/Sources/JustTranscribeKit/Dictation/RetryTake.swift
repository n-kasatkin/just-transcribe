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
        let ready = needsWAVConversion(file, for: model) ? try AudioConverter.wav(from: file) : file
        let audio = try AVAudioFile(forReading: ready)
        return (ready, .seconds(Double(audio.length) / audio.fileFormat.sampleRate))
    }
}

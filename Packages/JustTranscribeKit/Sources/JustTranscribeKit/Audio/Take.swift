import Foundation

/// What became of a finished recording.
public enum TakeResult: Sendable, Equatable {
    /// Less than `Take.minimumSpeech` above the gate threshold; nothing is saved or sent.
    case nothingHeard
    /// The trimmed take was saved; `duration` is its length in seconds.
    case saved(URL, duration: Double)
}

/// Turns captured samples into a recording file ready for `ostt transcribe`.
public enum Take {
    public static let minimumSpeech = 0.2

    /// Gates `samples` (16 kHz mono), saves the result to `store` in `container` and prunes the
    /// store to its newest recordings. Runs synchronously; call it off the main actor.
    public static func save(
        _ samples: [Float], as container: AudioContainer, in store: RecordingStore, date: Date = .now
    ) throws -> TakeResult {
        let gated = SpeechGate.apply(to: samples)
        guard gated.speechDuration >= minimumSpeech else { return .nothingHeard }
        let url = try store.newRecordingURL(container, date: date)
        try AudioFileWriter.write(gated.samples, to: url, as: container)
        try store.prune()
        return .saved(url, duration: Double(gated.samples.count) / Double(SpeechGate.sampleRate))
    }
}

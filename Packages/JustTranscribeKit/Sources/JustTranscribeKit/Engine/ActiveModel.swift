import Foundation

/// The audio container ostt should get for the active model.
public enum EngineAudioFormat: Sendable, Equatable {
    case m4a
    case wav
}

/// The model `ostt model current` reports: `PROVIDER/MODEL`, or none for "No model selected.".
public struct ActiveModel: Sendable, Equatable {
    public enum ParseError: Error, Sendable, Equatable {
        case unrecognized(String)
    }

    /// Providers that need WAV input: transcribe.cpp models and the user's own command.
    public static let wavProviders: Set<String> = ["whisper", "parakeet", "command"]

    public var providerID: String
    public var modelID: String

    public init(providerID: String, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }

    public var audioFormat: EngineAudioFormat {
        Self.wavProviders.contains(providerID) ? .wav : .m4a
    }

    /// Parses `ostt model current` stdout; nil means no model is selected.
    public static func parse(_ output: String) throws(ParseError) -> ActiveModel? {
        let line = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if line == "No model selected." { return nil }
        // ostt splits on the first slash only (`src/config/selection.rs`).
        guard !line.contains(where: \.isNewline), let slash = line.firstIndex(of: "/") else {
            throw .unrecognized(line)
        }
        let provider = line[..<slash]
        let model = line[line.index(after: slash)...]
        guard !provider.isEmpty, !model.isEmpty, !provider.contains(where: \.isWhitespace) else {
            throw .unrecognized(line)
        }
        return ActiveModel(providerID: String(provider), modelID: String(model))
    }

    /// Runs `ostt model current` with the 20 s CLI query timeout.
    public static func current(using runner: any OsttRunning) async throws -> ActiveModel? {
        let result = try await runner.run(["model", "current"], timeout: .seconds(20), onStderr: nil)
        return try parse(result.stdout)
    }
}

import Foundation

/// Transcribes an audio file with `ostt transcribe FILE -m MODEL [--param key=value]...`, which prints
/// the text to stdout (`src/commands/output.rs`) and touches the clipboard only with `-c` or `--paste`.
/// The model is named so the params always go to the model they were checked against.
public struct Transcriber: Sendable {
    public enum Failure: Error, Sendable, Equatable {
        /// ostt succeeded but returned no text; the recording is kept for Retry.
        case emptyTranscript
    }

    private let runner: any OsttRunning

    public init(runner: any OsttRunning) {
        self.runner = runner
    }

    /// The transcript as ostt printed it, minus the trailing newline.
    /// - Throws: `OsttError` from the runner, or `Failure.emptyTranscript`.
    /// - Parameter params: `--param key=value` pairs from `ModelParamArguments`.
    public func transcribe(
        file: URL,
        model: ActiveModel,
        params: [String] = [],
        audioDuration: Duration,
        onStderr: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let result = try await runner.run(
            ["transcribe", file.path(percentEncoded: false), "-m", "\(model.providerID)/\(model.modelID)"] + params,
            timeout: .seconds(30) + audioDuration,
            onStderr: onStderr
        )
        var text = Substring(result.stdout)
        while let last = text.last, last.isNewline {
            text.removeLast()
        }
        guard !text.allSatisfy(\.isWhitespace) else { throw Failure.emptyTranscript }
        return String(text)
    }
}

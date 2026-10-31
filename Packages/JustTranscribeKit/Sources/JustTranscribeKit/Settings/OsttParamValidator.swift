import Foundation

/// Checks a param value the way a take would, without sending audio. `ostt model params` lists only
/// names and types; ranges and allowed values are checked by `transcribe`, before it looks for an API
/// key or reads the audio. So `transcribe` of an empty file in a throwaway home either rejects the value
/// or stops later, at the missing key or the empty audio. Nothing is inherited from the app's
/// environment, so no key or config reaches that run.
public struct OsttParamValidator: Sendable {
    private let executableURL: URL

    public init(executableURL: URL) {
        self.executableURL = executableURL
    }

    /// - Returns: ostt's message when it rejects the value, without its "Error: " prefix; nil otherwise.
    public func rejection(_ name: String, _ value: ParamValue, model: OsttModelID) async throws -> String? {
        let home = FileManager.default.temporaryDirectory
            .appending(path: "just-transcribe-param-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let audio = home.appending(path: "take.wav")
        try Data().write(to: audio)
        let path = home.path(percentEncoded: false)
        let runner = ProcessOsttRunner(executableURL: executableURL, extraEnvironment: [
            "HOME": path,
            "XDG_CONFIG_HOME": "\(path)/config",
            "XDG_DATA_HOME": "\(path)/data",
            "XDG_STATE_HOME": "\(path)/state",
            "XDG_RUNTIME_DIR": "\(path)/run",
        ], inheriting: [:])
        do {
            _ = try await runner.run(
                ["transcribe", audio.path(percentEncoded: false), "-m", model.description, "--param", "\(name)=\(value.argument)"],
                timeout: OsttSettingsClient.queryTimeout, onStderr: nil
            )
            return nil
        } catch OsttError.failed(let result) {
            return Self.rejection(in: result.stderr)
        }
    }

    /// ostt's "Invalid param …" or "Invalid value for param …" line, the only failures that blame a param.
    static func rejection(in stderr: String) -> String? {
        stderr.split(whereSeparator: \.isNewline)
            .map { $0.hasPrefix("Error: ") ? String($0.dropFirst(7)) : String($0) }
            .first { $0.hasPrefix("Invalid param") || $0.hasPrefix("Invalid value for param") }
    }
}

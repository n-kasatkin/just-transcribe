import Foundation

/// Output of one finished ostt invocation.
public struct OsttResult: Sendable, Equatable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String

    public init(exitCode: Int32, stdout: String, stderr: String) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
    }

    /// The last non-empty stderr line, the short reason shown when a call fails.
    public var lastErrorLine: String? {
        stderr
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty })
    }
}

public enum OsttError: Error, Sendable, Equatable {
    /// `Contents/Helpers/ostt` is missing or not executable.
    case helperMissing
    /// The call ran past its timeout and was killed.
    case timedOut
    /// The calling task was cancelled and the process was killed.
    case cancelled
    /// ostt exited with a non-zero status.
    case failed(OsttResult)
}

/// Runs the ostt helper. The app uses a `Process`-backed runner; tests use fakes.
public protocol OsttRunning: Sendable {
    /// Runs `ostt <arguments>` and returns its output on exit status 0.
    /// - Throws: `OsttError.failed` on a non-zero exit, `.timedOut` after `timeout`,
    ///   `.cancelled` when the calling task is cancelled (the process is killed in both cases).
    /// - Parameter onStderr: receives stderr text as it arrives, for download progress.
    func run(
        _ arguments: [String],
        timeout: Duration,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> OsttResult
}

import Foundation
import Testing
@testable import JustTranscribeKit

/// Returns a canned result and records what it was asked to run.
private final class StubRunner: OsttRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: Result<OsttResult, OsttError>
    private(set) var calls: [(arguments: [String], timeout: Duration)] = []

    init(_ outcome: Result<OsttResult, OsttError>) {
        self.outcome = outcome
    }

    func run(_ arguments: [String], timeout: Duration, onStderr: (@Sendable (String) -> Void)?) async throws -> OsttResult {
        lock.withLock { calls.append((arguments, timeout)) }
        return try outcome.get()
    }
}

struct TranscriberTests {
    private func stdout(_ text: String) -> StubRunner {
        StubRunner(.success(OsttResult(exitCode: 0, stdout: text, stderr: "")))
    }

    @Test func runsTranscribeWithFileAndDurationTimeout() async throws {
        let runner = stdout("hello\n")
        let file = URL(filePath: "/tmp/rec dir/ostt-recording-20261031-120000-000.m4a")
        _ = try await Transcriber(runner: runner).transcribe(file: file, audioDuration: .seconds(12))
        #expect(runner.calls.count == 1)
        #expect(runner.calls.first?.arguments == ["transcribe", "/tmp/rec dir/ostt-recording-20261031-120000-000.m4a"])
        #expect(runner.calls.first?.timeout == .seconds(42))
    }

    @Test func dropsOnlyTheTrailingNewline() async throws {
        let text = try await Transcriber(runner: stdout("  Первая строка\n\nвторая 🙂 \n"))
            .transcribe(file: URL(filePath: "/tmp/a.wav"), audioDuration: .zero)
        #expect(text == "  Первая строка\n\nвторая 🙂 ")
    }

    @Test(arguments: ["", "\n", " \n", "\n\n"])
    func emptyTranscriptIsAnError(output: String) async {
        await #expect(throws: Transcriber.Failure.emptyTranscript) {
            try await Transcriber(runner: stdout(output)).transcribe(file: URL(filePath: "/tmp/a.wav"), audioDuration: .zero)
        }
    }

    @Test func runnerErrorsPassThrough() async {
        let failed = OsttResult(exitCode: 1, stdout: "", stderr: "Error: 401 Unauthorized\n")
        await #expect(throws: OsttError.failed(failed)) {
            try await Transcriber(runner: StubRunner(.failure(.failed(failed))))
                .transcribe(file: URL(filePath: "/tmp/a.wav"), audioDuration: .zero)
        }
    }

    @Test func endToEndThroughFakeOstt() async throws {
        let fake = try FakeOstt(script: "[ \"$1\" = transcribe ] && [ -n \"$2\" ] && echo 'Съешь же ещё этих мягких французских булок 🥐'")
        let text = try await Transcriber(runner: fake.runner)
            .transcribe(file: fake.file("take.m4a"), audioDuration: .seconds(1))
        #expect(text == "Съешь же ещё этих мягких французских булок 🥐")
    }
}

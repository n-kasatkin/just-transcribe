import Foundation
import Testing
@testable import JustTranscribeKit

struct ProcessOsttRunnerTests {
    /// Writes the script's pid atomically to `pid` in its own dir, then runs `body`.
    private static func announcingPID(_ body: String) -> String {
        "dir=$(dirname \"$0\")\necho $$ > \"$dir/pid.tmp\" && mv \"$dir/pid.tmp\" \"$dir/pid\"\n\(body)"
    }

    @Test func cyrillicAndEmojiStdoutComesBackIntact() async throws {
        let text = "Привет, мир! Ёжик 🦔 и 👋🏽 test"
        let fake = try FakeOstt(script: "printf '%s\\n' '\(text)'")
        defer { fake.remove() }
        let result = try await fake.runner.run([], timeout: .seconds(10), onStderr: nil)
        #expect(result.stdout == text + "\n")
        #expect(result.exitCode == 0)
    }

    @Test func passesArgumentsAndEnvironment() async throws {
        let fake = try FakeOstt(script: "printf '%s|' \"$@\"; printf '%s|%s' \"$LC_ALL\" \"$XDG_CONFIG_HOME\"")
        defer { fake.remove() }
        let result = try await fake.runner.run(["transcribe", "/a b/ c.m4a"], timeout: .seconds(10), onStderr: nil)
        let config = fake.directory.path(percentEncoded: false) + "/config"
        #expect(result.stdout == "transcribe|/a b/ c.m4a|en_US.UTF-8|\(config)")
    }

    @Test func nonZeroExitFailsWithLastStderrLine() async throws {
        let fake = try FakeOstt(script: "echo partial; echo 'Transcribing…' >&2; echo 'Error: 401 Unauthorized' >&2; exit 1")
        defer { fake.remove() }
        let error = await #expect(throws: OsttError.self) {
            try await fake.runner.run([], timeout: .seconds(10), onStderr: nil)
        }
        guard case .failed(let result) = error else {
            Issue.record("expected .failed, got \(String(describing: error))")
            return
        }
        #expect(result.exitCode == 1)
        #expect(result.stdout == "partial\n")
        #expect(result.lastErrorLine == "Error: 401 Unauthorized")
    }

    @Test func hangTimesOutAndProcessIsGone() async throws {
        let fake = try FakeOstt(script: Self.announcingPID("sleep 30"))
        defer { fake.remove() }
        let clock = ContinuousClock()
        let start = clock.now
        await #expect(throws: OsttError.timedOut) {
            try await fake.runner.run([], timeout: .seconds(2), onStderr: nil)
        }
        #expect(clock.now - start < .seconds(8))
        #expect(!processExists(try readPID(fake.file("pid"))))
    }

    @Test func processIgnoringSIGTERMIsKilled() async throws {
        let fake = try FakeOstt(script: "trap '' TERM\n" + Self.announcingPID("while :; do sleep 0.1; done"))
        defer { fake.remove() }
        await #expect(throws: OsttError.timedOut) {
            try await fake.runner.run([], timeout: .seconds(2), onStderr: nil)
        }
        #expect(!processExists(try readPID(fake.file("pid"))))
    }

    @Test func largeStdoutAndStderrDoNotDeadlock() async throws {
        // stderr is written first, so a runner reading only stdout would block the script.
        let fake = try FakeOstt(script: """
            head -c 204800 /dev/zero | tr '\\0' e >&2
            head -c 204800 /dev/zero | tr '\\0' o
            """)
        defer { fake.remove() }
        let result = try await fake.runner.run([], timeout: .seconds(20), onStderr: nil)
        #expect(result.stdout.utf8.count == 204_800)
        #expect(result.stderr.utf8.count == 204_800)
        #expect(result.stdout.allSatisfy { $0 == "o" })
    }

    @Test func cancellingTheTaskKillsTheProcess() async throws {
        let fake = try FakeOstt(script: Self.announcingPID("sleep 30"))
        defer { fake.remove() }
        let runner = fake.runner
        let task = Task { try await runner.run([], timeout: .seconds(60), onStderr: nil) }
        try await waitForFile(fake.file("pid"))
        let pid = try readPID(fake.file("pid"))
        #expect(processExists(pid))
        task.cancel()
        await #expect(throws: OsttError.cancelled) { try await task.value }
        #expect(!processExists(pid))
    }

    @Test func alreadyCancelledTaskDoesNotLaunch() async throws {
        let fake = try FakeOstt(script: Self.announcingPID("echo ran"))
        defer { fake.remove() }
        let runner = fake.runner
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runner.run([], timeout: .seconds(10), onStderr: nil)
        }
        await #expect(throws: OsttError.cancelled) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: fake.file("pid").path(percentEncoded: false)))
    }

    @Test func stderrChunksReachOnStderrAsTheyArrive() async throws {
        let fake = try FakeOstt(script: """
            printf '\\r 10.0%%  1 MB / 10 MB' >&2
            sleep 0.3
            printf '\\r 100.0%%  10 MB / 10 MB' >&2
            sleep 0.3
            echo done
            """)
        defer { fake.remove() }
        let chunks = Collector<String>()
        let result = try await fake.runner.run([], timeout: .seconds(10)) { chunks.append($0) }
        #expect(chunks.values.count >= 2)
        #expect(chunks.values.joined() == result.stderr)
        #expect(result.stderr.contains("100.0%"))
        #expect(result.stdout == "done\n")
    }

    @Test func multiByteCharacterSplitAcrossStderrReadsIsNotGarbled() async throws {
        // "П" is D0 9F; the sleep makes the two bytes arrive in separate reads.
        let fake = try FakeOstt(script: "printf '\\320' >&2; sleep 0.3; printf '\\237\\n' >&2")
        defer { fake.remove() }
        let chunks = Collector<String>()
        let result = try await fake.runner.run([], timeout: .seconds(10)) { chunks.append($0) }
        #expect(result.stderr == "П\n")
        #expect(chunks.values.count == 1)
        #expect(chunks.values.joined() == "П\n")
    }

    @Test(arguments: [
        ([0x61], 1),
        ([0x61, 0xD0], 1),
        ([0x61, 0xD0, 0x9F], 3),
        ([0xE2, 0x80], 0),
        ([0xE2, 0x80, 0xA6], 3),
        ([0x61, 0xF0, 0x9F, 0xA6], 1),
        ([0xF0, 0x9F, 0xA6, 0x94], 4),
    ] as [([UInt8], Int)])
    func completeUTF8LengthHoldsBackOnlyAnUnfinishedSequence(bytes: [UInt8], expected: Int) {
        #expect(ProcessOsttRunner.completeUTF8Length(Data(bytes)) == expected)
    }

    @Test func pipesAreClosedWhenTheCallReturnsNotWhenTheTimeoutFires() async throws {
        func openDescriptors() throws -> Int {
            try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
        }
        let runner = ProcessOsttRunner(executableURL: URL(filePath: "/bin/echo"))
        let before = try openDescriptors()
        for _ in 0..<200 {
            _ = try await runner.run([], timeout: .seconds(120), onStderr: nil)
        }
        // Holding the pipes until the timeout would add 400 descriptors; tests running in parallel
        // account for up to about 60.
        #expect(try openDescriptors() - before < 150)
    }

    @Test func missingExecutableIsHelperMissing() async throws {
        let runner = ProcessOsttRunner(executableURL: URL(filePath: "/nonexistent/jt-\(UUID().uuidString)/ostt"))
        await #expect(throws: OsttError.helperMissing) {
            try await runner.run([], timeout: .seconds(5), onStderr: nil)
        }
    }

    @Test func extraEnvironmentOverridesInherited() {
        let runner = ProcessOsttRunner(
            executableURL: URL(filePath: "/bin/true"),
            extraEnvironment: ["XDG_DATA_HOME": "/tmp/x", "LANG": "C"],
            inheriting: ["XDG_DATA_HOME": "/home/u/.local/share", "PATH": "/usr/bin"]
        )
        #expect(runner.environment["XDG_DATA_HOME"] == "/tmp/x")
        #expect(runner.environment["LANG"] == "C")
        #expect(runner.environment["LC_ALL"] == "en_US.UTF-8")
        #expect(runner.environment["PATH"]?.hasPrefix("/usr/bin:/opt/homebrew/bin") == true)
    }
}

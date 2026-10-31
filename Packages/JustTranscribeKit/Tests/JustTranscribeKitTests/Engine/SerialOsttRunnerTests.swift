import Foundation
import Testing
@testable import JustTranscribeKit

struct SerialOsttRunnerTests {
    /// Records `$1` in `log`; `mkdir` on a lock dir is atomic, so an overlapping call logs "overlap".
    private static let lockingScript = """
        dir=$(dirname "$0")
        mkdir "$dir/lock" 2>/dev/null || echo overlap >> "$dir/log"
        echo "start $1" >> "$dir/log"
        sleep 0.15
        echo "end $1" >> "$dir/log"
        rmdir "$dir/lock"
        """

    private func log(of fake: FakeOstt) throws -> [String] {
        try String(contentsOf: fake.file("log"), encoding: .utf8).split(separator: "\n").map(String.init)
    }

    @Test func callsNeverOverlap() async throws {
        let fake = try FakeOstt(script: Self.lockingScript)
        let serial = SerialOsttRunner(fake.runner)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask { _ = try await serial.run(["\(index)"], timeout: .seconds(10), onStderr: nil) }
            }
            try await group.waitForAll()
        }
        let lines = try log(of: fake)
        #expect(!lines.contains("overlap"))
        #expect(lines.count == 10)
        for pair in stride(from: 0, to: lines.count, by: 2) {
            #expect(lines[pair].dropFirst("start ".count) == lines[pair + 1].dropFirst("end ".count))
        }
    }

    @Test func runsInArrivalOrder() async throws {
        let fake = try FakeOstt(script: Self.lockingScript)
        let serial = SerialOsttRunner(fake.runner)
        var tasks: [Task<OsttResult, any Error>] = []
        for index in 0..<3 {
            tasks.append(Task { try await serial.run(["\(index)"], timeout: .seconds(10), onStderr: nil) })
            try await Task.sleep(for: .milliseconds(50))
        }
        for task in tasks { _ = try await task.value }
        #expect(try log(of: fake) == ["start 0", "end 0", "start 1", "end 1", "start 2", "end 2"])
    }

    @Test func cancelledQueuedCallLeavesAtOnceAndQueueContinues() async throws {
        let fake = try FakeOstt(script: """
            dir=$(dirname "$0")
            echo "start $1" >> "$dir/log"
            [ "$1" = first ] && sleep 1
            echo "end $1" >> "$dir/log"
            """)
        let serial = SerialOsttRunner(fake.runner)
        let first = Task { try await serial.run(["first"], timeout: .seconds(10), onStderr: nil) }
        try await Task.sleep(for: .milliseconds(100))
        let queued = Task { try await serial.run(["queued"], timeout: .seconds(10), onStderr: nil) }
        try await Task.sleep(for: .milliseconds(50))
        let last = Task { try await serial.run(["last"], timeout: .seconds(10), onStderr: nil) }
        try await Task.sleep(for: .milliseconds(50))

        let clock = ContinuousClock()
        let cancelledAt = clock.now
        queued.cancel()
        await #expect(throws: OsttError.cancelled) { try await queued.value }
        #expect(clock.now - cancelledAt < .milliseconds(500))

        _ = try await first.value
        _ = try await last.value
        #expect(try log(of: fake) == ["start first", "end first", "start last", "end last"])
    }

    @Test func failureReleasesTheQueue() async throws {
        let fake = try FakeOstt(script: "[ \"$1\" = bad ] && { echo 'Error: boom' >&2; exit 1; }\necho ok")
        let serial = SerialOsttRunner(fake.runner)
        await #expect(throws: OsttError.self) {
            try await serial.run(["bad"], timeout: .seconds(10), onStderr: nil)
        }
        let result = try await serial.run(["good"], timeout: .seconds(10), onStderr: nil)
        #expect(result.stdout == "ok\n")
    }
}

import Foundation
import os
import Testing
@testable import JustTranscribeKit

/// Records every call and answers with `handler`.
private final class FakeRunner: OsttRunning {
    typealias Handler = @Sendable ([String], (@Sendable (String) -> Void)?) async throws -> OsttResult
    private let handler: Handler
    private let log = OSAllocatedUnfairLock(initialState: [(arguments: [String], timeout: Duration)]())

    init(stdout: String = "") {
        handler = { _, _ in OsttResult(exitCode: 0, stdout: stdout, stderr: "") }
    }

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var calls: [(arguments: [String], timeout: Duration)] { log.withLock { $0 } }

    func run(_ arguments: [String], timeout: Duration, onStderr: (@Sendable (String) -> Void)?) async throws -> OsttResult {
        log.withLock { $0.append((arguments, timeout)) }
        return try await handler(arguments, onStderr)
    }
}

struct OsttSettingsClientTests {
    @Test func listsModelsWithQueryTimeout() async throws {
        let runner = FakeRunner(stdout: OsttOutputTests.cloudList)
        let models = try await OsttSettingsClient(runner: runner).listModels(provider: "elevenlabs")
        #expect(models.count == 2)
        #expect(models.allSatisfy { $0.sizeMB == nil })
        #expect(runner.calls.map(\.arguments) == [["model", "list", "--provider", "elevenlabs", "--format", "json"]])
        #expect(runner.calls.map(\.timeout) == [.seconds(20)])
    }

    @Test func addsLocalModelSizesWhenPathsAreGiven() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jt-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OsttPaths(configDirectory: root.appending(path: "c"), dataDirectory: root.appending(path: "d"))
        try FileManager.default.createDirectory(at: paths.modelsDirectory, withIntermediateDirectories: true)
        try Data(#"[{"id": "turbo-q5_0", "provider_id": "whisper", "size_mb": 547}]"#.utf8)
            .write(to: paths.modelsDirectory.appending(path: "registry.json"))

        let models = try await OsttSettingsClient(runner: FakeRunner(stdout: OsttOutputTests.whisperList), paths: paths)
            .listModels(provider: "whisper")
        #expect(models.map(\.sizeMB) == [nil, 547, nil])
    }

    @Test func passesRunnerErrorsThrough() async {
        let failure = OsttResult(exitCode: 1, stdout: "", stderr: "Error: Keyword not found: nope\n")
        let client = OsttSettingsClient(runner: FakeRunner { _, _ in throw OsttError.failed(failure) })
        await #expect(throws: OsttError.failed(failure)) { try await client.removeKeyword("nope") }
        let slow = OsttSettingsClient(runner: FakeRunner { _, _ in throw OsttError.timedOut })
        await #expect(throws: OsttError.timedOut) { try await slow.listModels(provider: "whisper") }
    }

    @Test func buildsCommandLines() async throws {
        let runner = FakeRunner(stdout: "[\"a\"]")
        let client = OsttSettingsClient(runner: runner)
        let id = OsttModelID(provider: "whisper", model: "base")
        try await client.selectModel(id)
        try await client.removeModel(id)
        try await client.addKeyword("-dash")
        try await client.removeKeyword("Kubernetes")
        #expect(try await client.keywords() == ["a"])
        #expect(try await client.authorizedProviders() == ["a"])
        #expect(runner.calls.map(\.arguments) == [
            ["model", "select", "whisper/base"],
            ["model", "local", "remove", "whisper/base"],
            ["keyword", "add", "--", "-dash"],
            ["keyword", "remove", "--", "Kubernetes"],
            ["keyword", "list", "--format", "json"],
            ["auth", "list", "--format", "json"],
        ])
    }

    @Test func readsCurrentModel() async throws {
        #expect(try await OsttSettingsClient(runner: FakeRunner(stdout: "No model selected.\n")).currentModel() == nil)
        #expect(try await OsttSettingsClient(runner: FakeRunner(stdout: "groq/whisper-large-v3\n")).currentModel()
            == OsttModelID(provider: "groq", model: "whisper-large-v3"))
    }

    @Test func downloadReportsProgressInBothForms() async throws {
        let runner = FakeRunner { _, onStderr in
            onStderr?("Downloading local model: whisper/base\n")
            onStderr?("\r 50.0%  71 MB / 142 MB  10.0 MB/s")
            onStderr?("\r142 MB downloaded  10.0 MB/s")
            onStderr?("\n")
            return OsttResult(exitCode: 0, stdout: "Downloaded local model: whisper/base\n", stderr: "")
        }
        let updates = OSAllocatedUnfairLock(initialState: [DownloadProgress]())
        try await OsttSettingsClient(runner: runner)
            .downloadModel(OsttModelID(provider: "whisper", model: "base")) { update in updates.withLock { $0.append(update) } }

        #expect(updates.withLock { $0 }.map(\.fraction) == [0.5, nil])
        #expect(runner.calls.map(\.arguments) == [["model", "local", "download", "whisper/base"]])
        #expect(runner.calls.map(\.timeout) == [OsttSettingsClient.downloadTimeout])
    }

    @Test func steadyProgressOutlastsStallTimeout() async throws {
        let runner = FakeRunner { _, onStderr in
            for step in 1...10 {
                try await Task.sleep(for: .milliseconds(50))
                onStderr?("\r\(step * 10).0%  \(step) MB / 10 MB  1.0 MB/s")
            }
            return OsttResult(exitCode: 0, stdout: "", stderr: "")
        }
        let client = OsttSettingsClient(runner: runner, stallTimeout: .milliseconds(200))
        try await client.downloadModel(OsttModelID(provider: "whisper", model: "base")) { _ in }
    }

    @Test func stalledDownloadIsStopped() async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeRunner { _, onStderr in
            onStderr?("\r  1.0%  1 MB / 100 MB  1.0 MB/s")
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                cancelled.withLock { $0 = true }
                throw OsttError.cancelled
            }
            return OsttResult(exitCode: 0, stdout: "", stderr: "")
        }
        let client = OsttSettingsClient(runner: runner, stallTimeout: .milliseconds(200))
        let start = ContinuousClock.now
        await #expect(throws: OsttSettingsError.downloadStalled) {
            try await client.downloadModel(OsttModelID(provider: "whisper", model: "base")) { _ in }
        }
        #expect(cancelled.withLock { $0 })
        #expect(ContinuousClock.now - start < .seconds(5))
    }

    @Test func cancellingTheCallerStopsTheDownload() async throws {
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let runner = FakeRunner { _, onStderr in
            while true {
                do {
                    try await Task.sleep(for: .milliseconds(20))
                } catch {
                    cancelled.withLock { $0 = true }
                    throw OsttError.cancelled
                }
                onStderr?("\r1 MB downloaded  1.0 MB/s")
            }
        }
        let task = Task {
            try await OsttSettingsClient(runner: runner).downloadModel(OsttModelID(provider: "whisper", model: "base")) { _ in }
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: OsttError.cancelled) { try await task.value }
        #expect(cancelled.withLock { $0 })
    }

    @Test func listsLocalModelsInOneCallSplitByProvider() async throws {
        let rows = """
            [
              {"active": false, "installed": null, "model": "scribe_v2", "name": "Scribe v2", "provider": "elevenlabs"},
              {"active": false, "installed": false, "model": "turbo-q5_0", "name": "Whisper Large v3 Turbo Q5_0", "provider": "whisper"},
              {"active": true, "installed": true, "model": "base", "name": "Whisper Base", "provider": "whisper"},
              {"active": false, "installed": false, "model": "parakeet-tdt-0.6b-v3", "name": "Parakeet TDT 0.6B v3", "provider": "parakeet"}
            ]
            """
        let runner = FakeRunner(stdout: rows)
        let lists = try await OsttSettingsClient(runner: runner).listLocalModels()
        #expect(lists.mapValues { $0.map(\.id.model) } == ["whisper": ["turbo-q5_0", "base"], "parakeet": ["parakeet-tdt-0.6b-v3"]])
        #expect(runner.calls.map(\.arguments) == [["model", "list", "--format", "json"]])
        #expect(runner.calls.map(\.timeout) == [.seconds(20)])
    }

    @Test func configChangesGoThroughConfigRunner() async throws {
        let queries = FakeRunner(stdout: "[]"), changes = FakeRunner()
        let client = OsttSettingsClient(runner: queries, configRunner: changes)
        let id = OsttModelID(provider: "whisper", model: "base")
        try await client.selectModel(id)
        try await client.removeModel(id)
        try await client.addKeyword("a")
        try await client.removeKeyword("a")
        _ = try await client.keywords()
        _ = try await client.currentModel()
        #expect(changes.calls.map { $0.arguments.prefix(2) } == [["model", "select"], ["model", "local"], ["keyword", "add"], ["keyword", "remove"]])
        #expect(queries.calls.map { $0.arguments.prefix(2) } == [["keyword", "list"], ["model", "current"]])
    }

    @Test(arguments: [false, true])
    func stoppedDownloadRemovesItsPartialFile(stalled: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jt-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = OsttPaths(configDirectory: root.appending(path: "c"), dataDirectory: root.appending(path: "d"))
        try FileManager.default.createDirectory(at: paths.modelsDirectory, withIntermediateDirectories: true)
        let partial = paths.modelsDirectory.appending(path: "turbo-q5_0.tmp")
        let other = paths.modelsDirectory.appending(path: "base.tmp")
        let runner = FakeRunner { _, onStderr in
            try Data([1]).write(to: partial)
            onStderr?("\r  1.0%  1 MB / 548 MB  1.0 MB/s")
            do {
                try await Task.sleep(for: .seconds(30))
            } catch {
                throw OsttError.cancelled
            }
            return OsttResult(exitCode: 0, stdout: "", stderr: "")
        }
        try Data([1]).write(to: other)
        let client = OsttSettingsClient(runner: runner, paths: paths, stallTimeout: .milliseconds(stalled ? 200 : 30_000))
        let task = Task { try await client.downloadModel(OsttModel.recommendedID) { _ in } }
        if !stalled {
            try await Task.sleep(for: .milliseconds(200))
            task.cancel()
        }
        await #expect(throws: (any Error).self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: partial.path()))
        #expect(FileManager.default.fileExists(atPath: other.path()))
    }

    @Test func failedDownloadPassesOsttsErrorThrough() async throws {
        let failure = OsttResult(exitCode: 1, stdout: "", stderr: "Error: failed to download model: HTTP 404\n")
        let client = OsttSettingsClient(runner: FakeRunner { _, _ in throw OsttError.failed(failure) })
        await #expect(throws: OsttError.failed(failure)) {
            try await client.downloadModel(OsttModel.recommendedID) { _ in }
        }
    }
}

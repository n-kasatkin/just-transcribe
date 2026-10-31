import Foundation
import os
import Testing
@testable import JustTranscribeKit

struct SettingsStateTests {
    private static func whisper(_ id: String) -> OsttModel {
        OsttModel(id: OsttModelID(provider: "whisper", model: id), name: id, installed: false, active: false)
    }

    @Test func splitsLocalListsIntoSections() {
        let sections = SettingsState.localModels(.success(["whisper": [Self.whisper("base")], "parakeet": []]))
        #expect(sections["whisper"] == .loaded([Self.whisper("base")]))
        #expect(sections["parakeet"] == .failed(SettingsState.registryUnavailable))
    }

    /// ostt prints `[]` with exit 0 when the registry fetch fails and nothing is cached.
    @Test func emptyLocalListIsAnErrorWithRetry() {
        let sections = SettingsState.localModels(.success([:]))
        #expect(sections == ["whisper": .failed(SettingsState.registryUnavailable),
                             "parakeet": .failed(SettingsState.registryUnavailable)])
    }

    @Test func timeoutAndFailureBecomeErrors() {
        #expect(SettingsState.localModels(.failure(OsttError.timedOut))["whisper"] == .failed(SettingsState.registryTimedOut))
        let failure = OsttResult(exitCode: 1, stdout: "", stderr: "Error: no space left\n")
        #expect(SettingsState.localModels(.failure(OsttError.failed(failure)))["parakeet"] == .failed("Error: no space left"))
    }

    @Test func flagsSelectedCloudModelWithoutKey() {
        let scribe = OsttModelID(provider: "elevenlabs", model: "scribe_v2")
        #expect(SettingsState.currentModelMissingKey(scribe, providersWithKeys: []))
        #expect(!SettingsState.currentModelMissingKey(scribe, providersWithKeys: ["elevenlabs"]))
        #expect(!SettingsState.currentModelMissingKey(OsttModel.recommendedID, providersWithKeys: []))
        #expect(!SettingsState.currentModelMissingKey(nil, providersWithKeys: []))
    }

    @Test func dropsProgressAfterTheDownloadEnds() {
        let id = OsttModel.recommendedID
        let update = DownloadProgress(fraction: 0.5, downloaded: "1 MB", total: "2 MB", megabytesPerSecond: 1)
        var downloads = ActiveDownloads()
        downloads.update(id, update)
        #expect(!downloads.isDownloading(id))

        let started = downloads.start(id), startedTwice = downloads.start(id)
        #expect(started && !startedTwice)
        #expect(downloads.progress[id] == .some(nil))
        downloads.update(id, update)
        #expect(downloads.progress[id] == update)

        downloads.finish(id)
        downloads.update(id, update)
        #expect(!downloads.isDownloading(id))
    }
}

struct SerialOsttRunnerTests {
    /// Tracks how many calls run at once.
    private final class Probe: OsttRunning {
        private let state = OSAllocatedUnfairLock(initialState: (running: 0, peak: 0, order: [String]()))
        var peak: Int { state.withLock { $0.peak } }
        var order: [String] { state.withLock { $0.order } }

        func run(_ arguments: [String], timeout: Duration, onStderr: (@Sendable (String) -> Void)?) async throws -> OsttResult {
            state.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running); $0.order.append(arguments[0]) }
            defer { state.withLock { $0.running -= 1 } }
            do {
                try await Task.sleep(for: .milliseconds(30))
            } catch {
                throw OsttError.cancelled
            }
            if arguments[0] == "fail" { throw OsttError.timedOut }
            return OsttResult(exitCode: 0, stdout: arguments[0], stderr: "")
        }
    }

    @Test func runsOneCallAtATimeInOrder() async throws {
        let probe = Probe()
        let serial = SerialOsttRunner(probe)
        let names = (0..<6).map { $0 == 2 ? "fail" : "c\($0)" }
        var tasks: [Task<String, any Error>] = []
        for name in names {
            tasks.append(Task { try await serial.run([name], timeout: .seconds(1), onStderr: nil).stdout })
            // Lets each call reach the queue before the next one starts.
            try await Task.sleep(for: .milliseconds(2))
        }
        for (name, task) in zip(names, tasks) {
            if name == "fail" {
                await #expect(throws: OsttError.timedOut) { try await task.value }
            } else {
                #expect(try await task.value == name)
            }
        }
        #expect(probe.peak == 1)
        #expect(probe.order == names)
    }

    @Test func cancellingACallerStopsOnlyItsCall() async throws {
        let serial = SerialOsttRunner(Probe())
        let first = Task { try await serial.run(["a"], timeout: .seconds(1), onStderr: nil).stdout }
        let second = Task { try await serial.run(["b"], timeout: .seconds(1), onStderr: nil).stdout }
        second.cancel()
        await #expect(throws: OsttError.cancelled) { try await second.value }
        #expect(try await first.value == "a")
        #expect(try await serial.run(["c"], timeout: .seconds(1), onStderr: nil).stdout == "c")
    }
}

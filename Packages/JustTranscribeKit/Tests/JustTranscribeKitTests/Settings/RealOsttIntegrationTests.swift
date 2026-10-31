import Foundation
import Testing
@testable import JustTranscribeKit

/// Runs the real `vendor/ostt/ostt` in a throwaway home: HOME and every XDG directory point into a
/// fresh temp dir, so the owner's ostt config, keys and logs are never touched. Only commands that need
/// no network are used.
private final class SandboxedOstt: OsttRunning {
    static let helper = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "vendor/ostt/ostt")

    let root = FileManager.default.temporaryDirectory.appending(path: "jt-ostt-\(UUID().uuidString)", directoryHint: .isDirectory)
    var paths: OsttPaths {
        OsttPaths(environment: ["XDG_CONFIG_HOME": root.appending(path: "config").path(),
                                "XDG_DATA_HOME": root.appending(path: "data").path()], home: root)
    }

    init() throws {
        try #require(
            FileManager.default.isExecutableFile(atPath: Self.helper.path()),
            "ostt helper missing at \(Self.helper.path()); run scripts/fetch-ostt.sh"
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func run(_ arguments: [String], timeout: Duration, onStderr: (@Sendable (String) -> Void)?) async throws -> OsttResult {
        let process = Process()
        process.executableURL = Self.helper
        process.arguments = arguments
        process.environment = OsttHelper.environment(inheriting: [
            "HOME": root.path(),
            "XDG_CONFIG_HOME": root.appending(path: "config").path(),
            "XDG_DATA_HOME": root.appending(path: "data").path(),
            "XDG_STATE_HOME": root.appending(path: "state").path(),
            "XDG_RUNTIME_DIR": root.appending(path: "run").path(),
            "PATH": "/usr/bin:/bin",
        ])
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        // Kills ostt once `timeout` passes, so a hang ends the call instead of outliving the test.
        let watchdog = Task {
            try await Task.sleep(for: timeout)
            if process.isRunning { process.terminate() }
        }
        defer { watchdog.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        if Task.isCancelled { throw OsttError.cancelled }
        if process.terminationReason == .uncaughtSignal { throw OsttError.timedOut }
        // These commands print a few lines, well under the pipe buffer, so reading after exit is safe.
        let result = OsttResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
            stderr: String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
        guard result.exitCode == 0 else { throw OsttError.failed(result) }
        return result
    }
}

@Suite(.timeLimit(.minutes(1)))
struct RealOsttIntegrationTests {
    @Test func reportsTheBundledVersion() async throws {
        #expect(try await OsttSettingsClient(runner: try SandboxedOstt()).version() == "0.0.34")
    }

    @Test func keywordAddedByClientShowsInOsttKeywordList() async throws {
        let ostt = try SandboxedOstt()
        let client = OsttSettingsClient(runner: ostt)
        try await client.addKeyword("Kubernetes")
        try await client.addKeyword("-dash \"quoted\" Привет")

        let listed = try await ostt.run(["keyword", "list"], timeout: .seconds(20), onStderr: nil).stdout
        #expect(listed == "Kubernetes\n-dash \"quoted\" Привет\n")
        #expect(try await client.keywords() == ["Kubernetes", "-dash \"quoted\" Привет"])

        try await client.removeKeyword("Kubernetes")
        #expect(try await client.keywords() == ["-dash \"quoted\" Привет"])
        await #expect(throws: OsttError.self) { try await client.removeKeyword("Kubernetes") }
    }

    @Test func keySavedByStoreShowsInOsttAuthStatus() async throws {
        let ostt = try SandboxedOstt()
        let store = CredentialsStore(paths: ostt.paths)
        try store.setKey(provider: "elevenlabs", key: "test-key-123")

        let status = try await ostt.run(["auth", "status"], timeout: .seconds(20), onStderr: nil).stdout
        #expect(status == "Authenticated providers: elevenlabs\n")
        #expect(try await OsttSettingsClient(runner: ostt).authorizedProviders() == ["elevenlabs"])
    }

    @Test func escapedKeysAndForeignLinesStayReadableByOstt() async throws {
        let ostt = try SandboxedOstt()
        let store = CredentialsStore(paths: ostt.paths)
        try FileManager.default.createDirectory(at: ostt.paths.dataDirectory, withIntermediateDirectories: true)
        try Data("# added by hand\ngroq = 'gsk-literal'\n".utf8).write(to: ostt.paths.credentialsFile)
        try store.setKey(provider: "openai", key: "sk-\"quoted\"\\back\tslash\u{1}")
        try store.setKey(provider: "elevenlabs", key: "test-key-123")
        try store.removeKey(provider: "groq")

        let providers = try await OsttSettingsClient(runner: ostt).authorizedProviders()
        #expect(Set(providers) == ["openai", "elevenlabs"])
    }

    @Test func cloudModelSelectionNeedsTheKeyFirst() async throws {
        let ostt = try SandboxedOstt()
        let client = OsttSettingsClient(runner: ostt, paths: ostt.paths)
        #expect(try await client.currentModel() == nil)

        let models = try await client.listModels(provider: "elevenlabs")
        let scribe = try #require(models.first { $0.id.model == "scribe_v2" })
        #expect(scribe.installed == nil && !scribe.active)

        await #expect(throws: OsttError.self) { try await client.selectModel(scribe.id) }
        try CredentialsStore(paths: ostt.paths).setKey(provider: "elevenlabs", key: "test-key-123")
        try await client.selectModel(scribe.id)
        #expect(try await client.currentModel() == scribe.id)
        #expect(try await client.listModels(provider: "elevenlabs").first { $0.id == scribe.id }?.active == true)
    }
}

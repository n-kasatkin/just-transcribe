import Foundation
@testable import JustTranscribeKit

/// A temp dir holding a fake `ostt` shell script, with XDG dirs inside it so nothing reaches the
/// owner's real ostt config.
struct FakeOstt {
    let directory: URL
    let executable: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "jt-engine-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        executable = directory.appending(path: "ostt")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path(percentEncoded: false))
    }

    func file(_ name: String) -> URL {
        directory.appending(path: name)
    }

    var runner: ProcessOsttRunner {
        ProcessOsttRunner(executableURL: executable, extraEnvironment: isolatedEnvironment(in: directory))
    }
}

/// XDG and HOME pointed into `directory`, for any real or fake ostt run.
func isolatedEnvironment(in directory: URL) -> [String: String] {
    let path = directory.path(percentEncoded: false)
    return [
        "HOME": path,
        "XDG_CONFIG_HOME": "\(path)/config",
        "XDG_DATA_HOME": "\(path)/data",
        "XDG_STATE_HOME": "\(path)/state",
        "XDG_RUNTIME_DIR": "\(path)/run",
    ]
}

/// Thread-safe collector for values reported from callbacks.
final class Collector<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []

    func append(_ value: Value) {
        lock.withLock { storage.append(value) }
    }

    var values: [Value] {
        lock.withLock { storage }
    }
}

/// True while a process with this pid exists.
func processExists(_ pid: pid_t) -> Bool {
    kill(pid, 0) == 0 || errno == EPERM
}

func readPID(_ url: URL) throws -> pid_t {
    let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = pid_t(text) else { throw CocoaError(.fileReadCorruptFile) }
    return pid
}

/// Polls until `url` exists, for scripts that announce they started.
func waitForFile(_ url: URL, within limit: Duration = .seconds(5)) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while !FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
        guard clock.now < deadline else { throw CocoaError(.fileNoSuchFile) }
        try await Task.sleep(for: .milliseconds(20))
    }
}

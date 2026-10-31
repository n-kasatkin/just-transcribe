import Foundation

/// Runs an ostt executable with `Process`: the app passes `Contents/Helpers/ostt`, tests a fake script.
/// stdout and stderr are drained concurrently; a timeout or task cancellation kills the whole
/// process group (SIGTERM, then SIGKILL after a second).
public struct ProcessOsttRunner: OsttRunning {
    public let executableURL: URL
    /// `OsttHelper.environment(inheriting:)` with `extraEnvironment` laid over it.
    public let environment: [String: String]

    public init(
        executableURL: URL,
        extraEnvironment: [String: String] = [:],
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.executableURL = executableURL
        environment = OsttHelper.environment(inheriting: base).merging(extraEnvironment) { $1 }
    }

    public func run(
        _ arguments: [String],
        timeout: Duration,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> OsttResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let execution = Execution(process: process, onStderr: onStderr)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                execution.start(timeout: timeout, continuation: continuation)
            }
        } onCancel: {
            execution.stop(.cancelled)
        }
    }
}

/// One ostt invocation. All mutable state is guarded by `lock`; the continuation is resumed once.
private final class Execution: @unchecked Sendable {
    enum Stop { case timedOut, cancelled }

    private let process: Process
    private let onStderr: (@Sendable (String) -> Void)?
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private let lock = NSLock()
    private var continuation: CheckedContinuation<OsttResult, any Error>?
    private var stdout = Data()
    private var stderr = Data()
    private var stdoutOpen = true
    private var stderrOpen = true
    private var launched = false
    private var exited = false
    private var finished = false
    private var stopReason: Stop?

    init(process: Process, onStderr: (@Sendable (String) -> Void)?) {
        self.process = process
        self.onStderr = onStderr
    }

    func start(timeout: Duration, continuation: CheckedContinuation<OsttResult, any Error>) {
        lock.lock()
        if let stopReason {
            // Cancelled before launch.
            finished = true
            lock.unlock()
            continuation.resume(throwing: Self.error(for: stopReason))
            return
        }
        self.continuation = continuation
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        stdoutPipe.fileHandleForReading.readabilityHandler = { [self] in receive($0.availableData, fromStdout: true) }
        stderrPipe.fileHandleForReading.readabilityHandler = { [self] in receive($0.availableData, fromStdout: false) }
        process.terminationHandler = { [self] _ in processExited() }
        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            finished = true
            self.continuation = nil
            lock.unlock()
            continuation.resume(throwing: OsttError.helperMissing)
            return
        }
        launched = true
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.seconds(timeout)) { [self] in stop(.timedOut) }
    }

    func stop(_ reason: Stop) {
        lock.lock()
        guard !finished, stopReason == nil else { lock.unlock(); return }
        stopReason = reason
        let pid = launched && !exited ? process.processIdentifier : nil
        lock.unlock()
        guard let pid else { return }
        // Process makes the child a group leader; signalling the group also stops its children,
        // which would otherwise keep the pipes open.
        kill(-pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            if lock.withLock({ !finished }) { kill(-pid, SIGKILL) }
        }
    }

    private func receive(_ data: Data, fromStdout: Bool) {
        if data.isEmpty {
            closeStream(stdout: fromStdout)
            return
        }
        lock.withLock {
            if fromStdout { stdout.append(data) } else { stderr.append(data) }
        }
        if !fromStdout, let onStderr {
            onStderr(String(decoding: data, as: UTF8.self))
        }
    }

    private func processExited() {
        lock.withLock { exited = true }
        finishIfDone()
        // A grandchild may still hold a pipe open; ostt's own output is complete once it exits.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [self] in
            closeStream(stdout: true)
            closeStream(stdout: false)
        }
    }

    private func closeStream(stdout fromStdout: Bool) {
        let pipe = fromStdout ? stdoutPipe : stderrPipe
        pipe.fileHandleForReading.readabilityHandler = nil
        lock.withLock {
            if fromStdout { stdoutOpen = false } else { stderrOpen = false }
        }
        finishIfDone()
    }

    private func finishIfDone() {
        lock.lock()
        guard exited, !stdoutOpen, !stderrOpen, !finished, let continuation else {
            lock.unlock()
            return
        }
        finished = true
        self.continuation = nil
        let result = OsttResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self)
        )
        let stopReason = stopReason
        lock.unlock()
        if let stopReason {
            continuation.resume(throwing: Self.error(for: stopReason))
        } else if result.exitCode == 0, process.terminationReason == .exit {
            continuation.resume(returning: result)
        } else {
            continuation.resume(throwing: OsttError.failed(result))
        }
    }

    private static func error(for reason: Stop) -> OsttError {
        switch reason {
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

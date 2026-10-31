import Foundation

/// Runs calls of another runner one at a time, in arrival order, because ostt writes `ostt.toml`
/// non-atomically. A call cancelled while it waits leaves the queue with `OsttError.cancelled`.
public actor SerialOsttRunner: OsttRunning {
    private let base: any OsttRunning
    private var busy = false
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, any Error>)] = []

    public init(_ base: any OsttRunning) {
        self.base = base
    }

    public func run(
        _ arguments: [String],
        timeout: Duration,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> OsttResult {
        try await acquire()
        defer { release() }
        return try await base.run(arguments, timeout: timeout, onStderr: onStderr)
    }

    private func acquire() async throws {
        guard busy else {
            busy = true
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await wait(id)
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func wait(_ id: UUID) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            if Task.isCancelled {
                continuation.resume(throwing: OsttError.cancelled)
            } else {
                waiters.append((id, continuation))
            }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: OsttError.cancelled)
    }

    /// Hands the slot to the next waiter, so `busy` stays true while anyone is queued.
    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }
}

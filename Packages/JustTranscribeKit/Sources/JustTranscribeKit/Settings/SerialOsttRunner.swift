import Foundation
import os

/// Runs ostt calls one at a time, in call order, through `base`. ostt rewrites `ostt.toml`
/// non-atomically, so every call that changes it goes through one shared instance.
public final class SerialOsttRunner: OsttRunning {
    private let base: any OsttRunning
    private let tail = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    public init(_ base: any OsttRunning) {
        self.base = base
    }

    public func run(
        _ arguments: [String],
        timeout: Duration,
        onStderr: (@Sendable (String) -> Void)?
    ) async throws -> OsttResult {
        let base = base
        let call = tail.withLock { tail in
            let previous = tail
            let call = Task {
                await previous?.value
                return try await base.run(arguments, timeout: timeout, onStderr: onStderr)
            }
            tail = Task { _ = try? await call.value }
            return call
        }
        // A cancelled caller cancels its call, so the base runner stops ostt with `.cancelled`.
        return try await withTaskCancellationHandler {
            try await call.value
        } onCancel: {
            call.cancel()
        }
    }
}

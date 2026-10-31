import Foundation
import os

public enum OsttSettingsError: Error, Equatable, Sendable {
    /// ostt printed something other than the JSON it documents; carries the start of it.
    case unexpectedOutput(String)
    /// A download printed no progress for `OsttSettingsClient.stallTimeout` and was stopped.
    case downloadStalled
}

/// Typed calls to ostt's non-interactive model, keyword and auth commands (`src/app.rs`).
/// API keys are not written here: `ostt auth login` is interactive, so `CredentialsStore` writes them.
/// Calls that change `ostt.toml` (select, local remove, keyword add and remove) go through `configRunner`,
/// which the app shares with transcription as one `SerialOsttRunner`, since ostt rewrites that file non-atomically.
public struct OsttSettingsClient: Sendable {
    /// Every query, including the registry fetch behind a local `model list`, which ostt runs with no timeout.
    public static let queryTimeout: Duration = .seconds(20)
    /// The outer bound of a download; a stall is caught much earlier by `stallTimeout`.
    public static let downloadTimeout: Duration = .seconds(6 * 3600)

    private let runner: any OsttRunning
    private let configRunner: any OsttRunning
    private let modelsDirectory: URL?
    private let stallTimeout: Duration

    /// - Parameters:
    ///   - configRunner: runs the calls that change `ostt.toml`; `runner` when nil.
    ///   - paths: lets `listModels` fill in local model sizes from ostt's registry cache and lets a
    ///     stopped download remove its partial file.
    public init(
        runner: any OsttRunning,
        configRunner: (any OsttRunning)? = nil,
        paths: OsttPaths? = nil,
        stallTimeout: Duration = .seconds(60)
    ) {
        self.runner = runner
        self.configRunner = configRunner ?? runner
        modelsDirectory = paths?.modelsDirectory
        self.stallTimeout = stallTimeout
    }

    /// `model list --provider ID --format json`. For `whisper` and `parakeet` this fetches ostt's model
    /// registry from the network; `OsttError.timedOut` after `queryTimeout` means it could not.
    public func listModels(provider: String) async throws -> [OsttModel] {
        try await models(["model", "list", "--provider", provider, "--format", "json"])
    }

    /// Every Whisper and Parakeet model, keyed by provider, from one `model list --format json`: one
    /// registry fetch and one write of ostt's registry cache, which parallel lists could corrupt.
    public func listLocalModels() async throws -> [String: [OsttModel]] {
        Dictionary(grouping: try await models(["model", "list", "--format", "json"]).filter { $0.installed != nil },
                   by: \.id.provider)
    }

    private func models(_ arguments: [String]) async throws -> [OsttModel] {
        var models = try OsttOutput.models(try await run(arguments).stdout)
        if let modelsDirectory, models.contains(where: { $0.installed != nil }) {
            let sizes = OsttOutput.localModelSizes(in: modelsDirectory)
            for index in models.indices {
                models[index].sizeMB = sizes[models[index].id]
            }
        }
        return models
    }

    /// The helper's version, such as "0.0.34", from `--version`.
    public func version() async throws -> String {
        try OsttOutput.version(try await run(["--version"]).stdout)
    }

    /// The selected model, or nil when none is.
    public func currentModel() async throws -> OsttModelID? {
        OsttOutput.currentModel(try await run(["model", "current"]).stdout)
    }

    /// A cloud model needs its provider's key saved first, a local one its file downloaded.
    public func selectModel(_ id: OsttModelID) async throws {
        _ = try await run(["model", "select", id.description], on: configRunner)
    }

    /// Downloads a local model, reporting each progress update. Throws `OsttSettingsError.downloadStalled`
    /// and stops ostt when no output arrives for `stallTimeout`; cancelling the task stops it too.
    public func downloadModel(
        _ id: OsttModelID,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        do {
            try await runDownload(id, progress: progress)
        } catch OsttError.cancelled {
            removePartialDownload(id)
            throw OsttError.cancelled
        } catch OsttSettingsError.downloadStalled {
            removePartialDownload(id)
            throw OsttSettingsError.downloadStalled
        }
    }

    /// A killed ostt skips its own cleanup and leaves `models/<id>.tmp` (`download_file` in
    /// `local_models.rs` writes there before renaming), which can be gigabytes.
    private func removePartialDownload(_ id: OsttModelID) {
        guard let modelsDirectory else { return }
        try? FileManager.default.removeItem(at: modelsDirectory.appending(path: "\(id.model).tmp"))
    }

    private func runDownload(
        _ id: OsttModelID,
        progress: @escaping @Sendable (DownloadProgress) -> Void
    ) async throws {
        let watch = OSAllocatedUnfairLock(
            initialState: (parser: DownloadProgressParser(), lastOutput: ContinuousClock.now)
        )
        let stallTimeout = stallTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = try await runner.run(
                    ["model", "local", "download", id.description],
                    timeout: Self.downloadTimeout,
                    onStderr: { chunk in
                        let update = watch.withLock { state in
                            state.lastOutput = .now
                            return state.parser.feed(chunk)
                        }
                        if let update { progress(update) }
                    }
                )
            }
            group.addTask {
                while true {
                    do {
                        try await Task.sleep(for: min(stallTimeout / 4, .seconds(1)))
                    } catch {
                        // Cancelled: the download task reports how it ended.
                        return
                    }
                    if watch.withLock({ ContinuousClock.now - $0.lastOutput }) > stallTimeout {
                        throw OsttSettingsError.downloadStalled
                    }
                }
            }
            // A stall throws here and leaving the group cancels the download, which kills ostt.
            try await group.next()
            group.cancelAll()
            try await group.waitForAll()
        }
    }

    /// `model local remove`; ostt also stops its daemon when it serves this model.
    public func removeModel(_ id: OsttModelID) async throws {
        _ = try await run(["model", "local", "remove", id.description], on: configRunner)
    }

    public func keywords() async throws -> [String] {
        try OsttOutput.strings(try await run(["keyword", "list", "--format", "json"]).stdout)
    }

    /// Adding a keyword that is already listed changes nothing.
    public func addKeyword(_ keyword: String) async throws {
        // "--" keeps a keyword that starts with "-" from being read as an option.
        _ = try await run(["keyword", "add", "--", keyword], on: configRunner)
    }

    /// Fails with ostt's "Keyword not found" when it is not listed.
    public func removeKeyword(_ keyword: String) async throws {
        _ = try await run(["keyword", "remove", "--", keyword], on: configRunner)
    }

    /// Provider ids ostt finds a key for (`auth list --format json`).
    public func authorizedProviders() async throws -> [String] {
        try OsttOutput.strings(try await run(["auth", "list", "--format", "json"]).stdout)
    }

    private func run(_ arguments: [String], on runner: (any OsttRunning)? = nil) async throws -> OsttResult {
        try await (runner ?? self.runner).run(arguments, timeout: Self.queryTimeout, onStderr: nil)
    }
}

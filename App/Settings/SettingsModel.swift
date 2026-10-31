import AppKit
import JustTranscribeKit
import Observation

/// State and actions behind the Transcription, Offline models and Keywords tabs. Every ostt call goes
/// through the injected runner; API keys go straight to ostt's credentials file.
@Observable
final class SettingsModel {
    /// A value fetched from ostt, with the error text to show when that failed.
    enum Load<Value> {
        case idle, loading, loaded(Value), failed(String)

        var value: Value? {
            if case .loaded(let value) = self { value } else { nil }
        }
    }

    let paths: OsttPaths
    private let client: OsttSettingsClient
    private let credentials: CredentialsStore

    // Transcription
    private(set) var providerID = OsttProvider.cloud[0].id
    var keyDraft = ""
    private(set) var maskedKey: String?
    private(set) var providersWithKeys: Set<String> = []
    private(set) var cloudModels: Load<[OsttModel]> = .idle
    private(set) var currentModel: OsttModelID?
    private(set) var transcriptionError: String?

    // Offline models
    private(set) var localModels: [String: Load<[OsttModel]>] = [:]
    /// Models downloading now, with their latest progress (nil until ostt reports any).
    private(set) var downloads: [OsttModelID: DownloadProgress?] = [:]
    private var downloadTasks: [OsttModelID: Task<Void, Never>] = [:]
    private(set) var offlineError: String?

    // Keywords
    private(set) var keywords: Load<[String]> = .idle
    var keywordDraft = ""
    private(set) var keywordError: String?

    init(runner: any OsttRunning, paths: OsttPaths) {
        self.paths = paths
        client = OsttSettingsClient(runner: runner, paths: paths)
        credentials = CredentialsStore(paths: paths)
    }

    /// The selected model belongs to a cloud provider whose key is gone (Decision 4).
    var currentModelMissingKey: Bool {
        guard let currentModel, OsttProvider.withID(currentModel.provider)?.needsKey == true else { return false }
        return !providersWithKeys.contains(currentModel.provider)
    }

    // MARK: Transcription

    func loadTranscription() async {
        await refreshCurrentModel()
        if let provider = currentModel?.provider, OsttProvider.cloud.contains(where: { $0.id == provider }) {
            providerID = provider
        }
        refreshKey()
        await loadCloudModels()
    }

    func selectProvider(_ id: String) {
        guard id != providerID else { return }
        providerID = id
        keyDraft = ""
        transcriptionError = nil
        refreshKey()
        Task { await loadCloudModels() }
    }

    func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try credentials.setKey(provider: providerID, key: key)
            keyDraft = ""
            transcriptionError = nil
        } catch {
            transcriptionError = Self.message(for: error)
        }
        refreshKey()
    }

    func removeKey() {
        do {
            try credentials.removeKey(provider: providerID)
            transcriptionError = nil
        } catch {
            transcriptionError = Self.message(for: error)
        }
        refreshKey()
    }

    /// ostt refuses a cloud model until its provider's key is saved, so the view enables this only then.
    func useCloudModel(_ id: OsttModelID) async {
        do {
            try await client.selectModel(id)
            transcriptionError = nil
        } catch {
            transcriptionError = Self.message(for: error)
        }
        await refreshCurrentModel()
        await loadCloudModels()
    }

    private func loadCloudModels() async {
        let provider = providerID
        cloudModels = .loading
        let result: Load<[OsttModel]>
        do {
            result = .loaded(try await client.listModels(provider: provider))
        } catch {
            result = .failed(Self.message(for: error))
        }
        // A newer provider choice owns the list now.
        if provider == providerID { cloudModels = result }
    }

    private func refreshKey() {
        do {
            maskedKey = try credentials.maskedKey(provider: providerID)
            providersWithKeys = Set(try credentials.configuredProviders())
        } catch {
            maskedKey = nil
            transcriptionError = Self.message(for: error)
        }
    }

    private func refreshCurrentModel() async {
        currentModel = try? await client.currentModel()
    }

    // MARK: Offline models

    /// Fetches both local lists once; a failed one is fetched again with `loadLocalModels`.
    func loadOfflineModelsIfNeeded() async {
        await refreshCurrentModel()
        await withDiscardingTaskGroup { group in
            for provider in OsttProvider.local where localModels[provider.id]?.value == nil {
                group.addTask { await self.loadLocalModels(provider: provider.id) }
            }
        }
    }

    /// ostt fetches its model registry here, so a timeout means the network did not answer in 20 s.
    func loadLocalModels(provider: String) async {
        localModels[provider] = .loading
        do {
            localModels[provider] = .loaded(try await client.listModels(provider: provider))
        } catch OsttError.timedOut {
            localModels[provider] = .failed("The model list did not load within 20 seconds. Check the connection and retry.")
        } catch {
            localModels[provider] = .failed(Self.message(for: error))
        }
    }

    func recommendedModel(provider: String) -> OsttModelID? {
        localModels[provider]?.value.flatMap { OsttModel.recommended(in: $0) }
    }

    func download(_ id: OsttModelID) {
        guard downloadTasks[id] == nil else { return }
        offlineError = nil
        downloads[id] = .some(nil)
        downloadTasks[id] = Task {
            do {
                try await client.downloadModel(id) { progress in
                    Task { @MainActor in
                        // A late update must not bring back a finished download's row.
                        if self.downloads[id] != nil { self.downloads[id] = progress }
                    }
                }
            } catch OsttError.cancelled {
                // The user stopped it; nothing to report.
            } catch {
                offlineError = Self.message(for: error)
            }
            downloads[id] = nil
            downloadTasks[id] = nil
            await loadLocalModels(provider: id.provider)
        }
    }

    func cancelDownload(_ id: OsttModelID) {
        downloadTasks[id]?.cancel()
    }

    func useLocalModel(_ id: OsttModelID) async {
        await runOffline { try await self.client.selectModel(id) }
        await refreshCurrentModel()
        await loadLocalModels(provider: id.provider)
    }

    func removeLocalModel(_ id: OsttModelID) async {
        await runOffline { try await self.client.removeModel(id) }
        await refreshCurrentModel()
        await loadLocalModels(provider: id.provider)
    }

    private func runOffline(_ action: () async throws -> Void) async {
        do {
            try await action()
            offlineError = nil
        } catch {
            offlineError = Self.message(for: error)
        }
    }

    // MARK: Keywords

    func loadKeywords() async {
        if keywords.value == nil { keywords = .loading }
        do {
            keywords = .loaded(try await client.keywords())
        } catch {
            keywords = .failed(Self.message(for: error))
        }
    }

    func addKeyword() async {
        let keyword = keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return }
        await changeKeywords { try await self.client.addKeyword(keyword) }
        if keywordError == nil { keywordDraft = "" }
    }

    func removeKeyword(_ keyword: String) async {
        await changeKeywords { try await self.client.removeKeyword(keyword) }
    }

    private func changeKeywords(_ change: () async throws -> Void) async {
        do {
            try await change()
            keywordError = nil
        } catch {
            keywordError = Self.message(for: error)
        }
        await loadKeywords()
    }

    /// Opens `ostt.toml` in the app registered for it, else TextEdit, for replacements and advanced options.
    func openConfigFile() async {
        let file = paths.configFile
        if !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) {
            // Any ostt command writes the default config on its first run.
            _ = try? await client.keywords()
        }
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(toOpen: file) != nil {
            workspace.open(file)
        } else {
            _ = try? await workspace.open([file], withApplicationAt: URL(filePath: "/System/Applications/TextEdit.app"),
                                          configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // MARK: Errors

    static func message(for error: any Error) -> String {
        switch error {
        case OsttError.failed(let result):
            result.lastErrorLine ?? "ostt exited with status \(result.exitCode)."
        case OsttError.timedOut:
            "ostt did not answer within 20 seconds."
        case OsttError.helperMissing:
            "The bundled ostt helper is missing. Reinstall just transcribe."
        case OsttError.cancelled:
            "Cancelled."
        case OsttSettingsError.downloadStalled:
            "The download stalled: no progress for 60 seconds."
        case OsttSettingsError.unexpectedOutput:
            "ostt returned output this version of just transcribe cannot read."
        case CredentialsStore.Failure.multilineKey:
            "The key must be on one line."
        case CredentialsStore.Failure.unreadableFile:
            "ostt's credentials file is not plain text, so it was left unchanged."
        default:
            error.localizedDescription
        }
    }
}

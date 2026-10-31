import AppKit
import JustTranscribeKit
import Observation

/// State and actions behind the Transcription, Offline models and Keywords tabs. Every ostt call goes
/// through the injected runners; API keys go straight to ostt's credentials file.
@Observable
final class SettingsModel {
    let paths: OsttPaths
    private let client: OsttSettingsClient
    private let credentials: CredentialsStore

    // Transcription
    private(set) var providerID = OsttProvider.cloud[0].id
    var keyDraft = ""
    private(set) var maskedKey: String?
    private(set) var providersWithKeys: Set<String> = []
    private(set) var cloudModels: Loadable<[OsttModel]> = .idle
    private(set) var currentModel: OsttModelID?
    private(set) var transcriptionError: String?

    // Offline models
    private(set) var localModels: [String: Loadable<[OsttModel]>] = [:]
    private(set) var downloads = ActiveDownloads()
    private var downloadTasks: [OsttModelID: Task<Void, Never>] = [:]
    private(set) var offlineError: String?

    // Keywords
    private(set) var keywords: Loadable<[String]> = .idle
    var keywordDraft = ""
    private(set) var keywordError: String?

    /// Called after a model is selected or removed, so dictation re-reads the active model.
    @ObservationIgnored var onModelChange: (() -> Void)?

    /// - Parameter configRunner: the queue shared with transcription for calls that change `ostt.toml`;
    ///   without one, those calls are serialized among the settings only.
    init(runner: any OsttRunning, configRunner: (any OsttRunning)? = nil, paths: OsttPaths) {
        self.paths = paths
        client = OsttSettingsClient(runner: runner, configRunner: configRunner ?? SerialOsttRunner(runner), paths: paths)
        credentials = CredentialsStore(paths: paths)
    }

    /// The selected model belongs to a cloud provider whose key is gone (Decision 4).
    var currentModelMissingKey: Bool {
        SettingsState.currentModelMissingKey(currentModel, providersWithKeys: providersWithKeys)
    }

    var engineReadiness: EngineReadiness {
        EngineReadiness(current: currentModel, providersWithKeys: providersWithKeys)
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

    /// - Returns: whether a key was saved.
    @discardableResult func saveKey() -> Bool {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return false }
        defer { refreshKey() }
        do {
            try credentials.setKey(provider: providerID, key: key)
            keyDraft = ""
            transcriptionError = nil
            return true
        } catch {
            transcriptionError = SettingsState.message(for: error)
            return false
        }
    }

    /// Onboarding's one-step setup: saves the key, then selects the provider's recommended model.
    func saveKeyAndUseDefaultModel() async {
        let provider = providerID
        guard saveKey() else { return }
        do {
            let models = try await client.listModels(provider: provider)
            if let id = Onboarding.modelAfterSavingKey(provider: provider, current: currentModel, models: models) {
                await useCloudModel(id)
            }
        } catch {
            transcriptionError = SettingsState.message(for: error)
        }
    }

    /// Re-reads the selected model and the saved keys, for onboarding's engine row.
    func refreshEngine() async {
        await refreshCurrentModel()
        refreshKey()
    }

    func removeKey() {
        do {
            try credentials.removeKey(provider: providerID)
            transcriptionError = nil
        } catch {
            transcriptionError = SettingsState.message(for: error)
        }
        refreshKey()
    }

    /// ostt refuses a cloud model until its provider's key is saved, so the view enables this only then.
    func useCloudModel(_ id: OsttModelID) async {
        do {
            try await client.selectModel(id)
            transcriptionError = nil
        } catch {
            transcriptionError = SettingsState.message(for: error)
        }
        onModelChange?()
        await refreshCurrentModel()
        await loadCloudModels()
    }

    private func loadCloudModels() async {
        let provider = providerID
        cloudModels = .loading
        let result: Loadable<[OsttModel]>
        do {
            result = .loaded(try await client.listModels(provider: provider))
        } catch {
            result = .failed(SettingsState.message(for: error))
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
            transcriptionError = SettingsState.message(for: error)
        }
    }

    private func refreshCurrentModel() async {
        currentModel = try? await client.currentModel()
    }

    // MARK: Offline models

    /// Fetches the local lists once; Retry fetches them again with `loadLocalModels`.
    func loadOfflineModelsIfNeeded() async {
        await refreshCurrentModel()
        if OsttProvider.local.contains(where: { localModels[$0.id]?.value == nil }) {
            await loadLocalModels()
        }
    }

    /// ostt fetches its model registry here, so a timeout means the network did not answer in 20 s.
    func loadLocalModels() async {
        for provider in OsttProvider.local where localModels[provider.id]?.value == nil {
            localModels[provider.id] = .loading
        }
        let result: Result<[String: [OsttModel]], any Error>
        do {
            result = .success(try await client.listLocalModels())
        } catch {
            result = .failure(error)
        }
        localModels = SettingsState.localModels(result)
    }

    func recommendedModel(provider: String) -> OsttModelID? {
        localModels[provider]?.value.flatMap { OsttModel.recommended(in: $0) }
    }

    /// - Parameter thenUse: select the model once its download succeeds.
    func download(_ id: OsttModelID, thenUse: Bool = false) {
        guard downloads.start(id) else { return }
        offlineError = nil
        downloadTasks[id] = Task {
            var downloaded = false
            do {
                try await client.downloadModel(id) { progress in
                    Task { @MainActor in self.downloads.update(id, progress) }
                }
                downloaded = true
            } catch OsttError.cancelled {
                // The user stopped it; nothing to report.
            } catch {
                offlineError = SettingsState.message(for: error)
            }
            downloads.finish(id)
            downloadTasks[id] = nil
            if downloaded && thenUse {
                await useLocalModel(id)
            } else {
                await loadLocalModels()
            }
        }
    }

    func cancelDownload(_ id: OsttModelID) {
        downloadTasks[id]?.cancel()
    }

    func useLocalModel(_ id: OsttModelID) async {
        await runOffline { try await self.client.selectModel(id) }
        onModelChange?()
        await refreshCurrentModel()
        await loadLocalModels()
    }

    func removeLocalModel(_ id: OsttModelID) async {
        await runOffline { try await self.client.removeModel(id) }
        onModelChange?()
        await refreshCurrentModel()
        await loadLocalModels()
    }

    private func runOffline(_ action: () async throws -> Void) async {
        do {
            try await action()
            offlineError = nil
        } catch {
            offlineError = SettingsState.message(for: error)
        }
    }

    // MARK: Keywords

    func loadKeywords() async {
        if keywords.value == nil { keywords = .loading }
        do {
            keywords = .loaded(try await client.keywords())
        } catch {
            keywords = .failed(SettingsState.message(for: error))
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
            keywordError = SettingsState.message(for: error)
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
}

import Foundation
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

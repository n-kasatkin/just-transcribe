import Foundation
import Testing
@testable import JustTranscribeKit

final class AppPreferencesTests {
    private let suite = "AppPreferencesTests-\(UUID().uuidString)"
    private let defaults: UserDefaults
    private let root: URL
    private let paths: OsttPaths

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        root = try Signals.temporaryDirectory()
        paths = OsttPaths(
            configDirectory: root.appending(path: "config/ostt", directoryHint: .isDirectory),
            dataDirectory: root.appending(path: "data/ostt", directoryHint: .isDirectory)
        )
    }

    deinit {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    @Test func retentionCutoff() {
        let now = Date(timeIntervalSince1970: 1_793_448_000)
        #expect(RetentionPeriod.threeDays.cutoff(before: now) == now.addingTimeInterval(-3 * 86_400))
        #expect(RetentionPeriod.oneDay.cutoff(before: now) == now.addingTimeInterval(-86_400))
        #expect(RetentionPeriod.never.cutoff(before: now) == nil)
        #expect(RetentionPeriod.allCases.map(\.title) == ["1 day", "3 days", "7 days", "30 days", "Forever"])
    }

    @Test func retentionDefaultsAndStoredChoices() {
        let preferences = AppPreferences(defaults: defaults, paths: paths)
        #expect(preferences.recordingRetention == .threeDays)
        #expect(preferences.historyRetention == .thirtyDays)
        defaults.set(RetentionPeriod.never.rawValue, forKey: AppPreferences.recordingRetentionKey)
        defaults.set(RetentionPeriod.sevenDays.rawValue, forKey: AppPreferences.historyRetentionKey)
        #expect(preferences.recordingRetention == .never)
        #expect(preferences.historyRetention == .sevenDays)
        defaults.set(5, forKey: AppPreferences.recordingRetentionKey)
        #expect(preferences.recordingRetention == .threeDays)
    }

    @Test func menuBarIconShowsUntilHidden() {
        let preferences = AppPreferences(defaults: defaults, paths: paths)
        #expect(preferences.showMenuBarIcon)
        defaults.set(false, forKey: AppPreferences.showMenuBarIconKey)
        #expect(!preferences.showMenuBarIcon)
    }

    @Test func recordingsFolderDefaultsToOstts() {
        let preferences = AppPreferences(defaults: defaults, paths: paths)
        #expect(preferences.recordingsDirectory == paths.recordingsDirectory)
        defaults.set("", forKey: AppPreferences.recordingsFolderKey)
        #expect(preferences.recordingsDirectory == paths.recordingsDirectory)
    }

    @Test func cleanupCoversTheCurrentOsttsAndEarlierFolders() {
        let preferences = AppPreferences(defaults: defaults, paths: paths)
        #expect(preferences.cleanedRecordingStores.map(\.directory) == [paths.recordingsDirectory])

        let first = root.appending(path: "first", directoryHint: .isDirectory).path(percentEncoded: false)
        let second = root.appending(path: "second", directoryHint: .isDirectory).path(percentEncoded: false)
        defaults.set(first, forKey: AppPreferences.recordingsFolderKey)
        preferences.leaveRecordingsFolder(first)
        defaults.set(second, forKey: AppPreferences.recordingsFolderKey)
        preferences.leaveRecordingsFolder(first)
        preferences.leaveRecordingsFolder("")

        let stores = preferences.cleanedRecordingStores
        #expect(stores.map { $0.directory.path(percentEncoded: false) }
            == [second, paths.recordingsDirectory.path(percentEncoded: false), first])
        #expect(stores.map(\.isOsttFolder) == [false, true, false])
    }

    @Test func folderChangeAppliesToTheNextSave() throws {
        let preferences = AppPreferences(defaults: defaults, paths: paths)
        let speech = Signals.tone(seconds: 0.5)
        guard case .saved(let first, _) = try Take.save(speech, as: .wav, in: preferences.recordingStore) else {
            Issue.record("expected a saved take")
            return
        }
        #expect(first.deletingLastPathComponent().path() == paths.recordingsDirectory.path())

        let chosen = root.appending(path: "My Takes", directoryHint: .isDirectory)
        defaults.set(chosen.path(percentEncoded: false), forKey: AppPreferences.recordingsFolderKey)
        guard case .saved(let second, _) = try Take.save(speech, as: .wav, in: preferences.recordingStore) else {
            Issue.record("expected a saved take")
            return
        }
        #expect(second.deletingLastPathComponent().path() == chosen.path())
        #expect(preferences.recordingStore.latestRecording() == second)
    }
}

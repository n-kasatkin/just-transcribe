import Foundation
import Testing
@testable import JustTranscribeKit

final class RecordingStoreTests {
    private let root: URL

    init() throws {
        root = try Signals.temporaryDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore() throws -> RecordingStore {
        RecordingStore(paths: OsttPaths(
            configDirectory: root.appending(path: "config/ostt", directoryHint: .isDirectory),
            dataDirectory: root.appending(path: "data/ostt", directoryHint: .isDirectory)
        ))
    }

    private func touch(_ store: RecordingStore, _ name: String) {
        FileManager.default.createFile(atPath: store.directory.appending(path: name).path(percentEncoded: false), contents: Data())
    }

    @Test func namesFollowOstt() throws {
        let store = try makeStore()
        let date = Date(timeIntervalSince1970: 1_793_448_000.042) // 2026-10-31 12:00:00.042 UTC
        let url = try store.newRecordingURL(.m4a, date: date, timeZone: try #require(TimeZone(identifier: "UTC")))
        #expect(url.lastPathComponent == "ostt-recording-20261031-120000-042.m4a")
        #expect(url.deletingLastPathComponent().path() == store.directory.path())

        let local = try store.newRecordingURL(.wav).lastPathComponent
        #expect(local.wholeMatch(of: /ostt-recording-\d{8}-\d{6}-\d{3}\.wav/) != nil)
    }

    @Test func createsDirectoryPrivately() throws {
        let store = try makeStore()
        _ = try store.newRecordingURL(.m4a)
        let attributes = try FileManager.default.attributesOfItem(atPath: store.directory.path(percentEncoded: false))
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    @Test func tightensAnExistingDirectory() throws {
        let store = try makeStore()
        try FileManager.default.createDirectory(
            at: store.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )
        _ = try store.newRecordingURL(.m4a)
        #expect(try mode(store.directory) == 0o700)
        #expect(try mode(store.directory.deletingLastPathComponent()) != 0o700)
    }

    @Test func leavesAChosenFolderModeAlone() throws {
        let chosen = root.appending(path: "Shared Takes", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let store = RecordingStore(directory: chosen)
        _ = try store.newRecordingURL(.m4a)
        #expect(try mode(chosen) == 0o755)

        let created = RecordingStore(directory: root.appending(path: "New Takes", directoryHint: .isDirectory))
        _ = try created.newRecordingURL(.m4a)
        #expect(try mode(created.directory) == 0o700)
    }

    private func mode(_ url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }

    private func touch(_ store: RecordingStore, _ name: String, created: Date) throws {
        touch(store, name)
        let path = store.directory.appending(path: name).path(percentEncoded: false)
        try FileManager.default.setAttributes([.creationDate: created], ofItemAtPath: path)
    }

    @Test func latestIsTheNewestRecording() throws {
        let store = try makeStore()
        #expect(store.latestRecording() == nil)
        _ = try store.newRecordingURL(.m4a)
        let names = (1...13).map { String(format: "ostt-recording-20261031-1200%02d-000.%@", $0, $0.isMultiple(of: 2) ? "wav" : "m4a") }
        for name in names.shuffled() { touch(store, name) }
        touch(store, "notes.txt")
        try FileManager.default.createDirectory(at: store.directory.appending(path: "ostt-recording-zz"), withIntermediateDirectories: true)

        #expect(store.latestRecording()?.lastPathComponent == names.last)
        #expect(store.recordings().map(\.lastPathComponent) == names.reversed())
    }

    @Test func deletesOnlyRecordingsOlderThanTheCutoff() throws {
        let store = try makeStore()
        try store.prepareDirectory()
        let now = Date.now
        let old = now.addingTimeInterval(-4 * 86_400)
        let oldM4a = try store.newRecordingURL(.m4a, date: old).lastPathComponent
        let oldWav = try store.newRecordingURL(.wav, date: old.addingTimeInterval(1)).lastPathComponent
        let recent = try store.newRecordingURL(.m4a, date: now.addingTimeInterval(-3600)).lastPathComponent
        // A fresh file under an old take's name, as Retry's WAV conversion writes, is old too.
        for name in [oldM4a, oldWav, recent] { try touch(store, name, created: now) }
        let unnamed = "ostt-recording-garbage.m4a"
        try touch(store, unnamed, created: old)
        let foreign = ["notes.txt", "my-ostt-recording-1.m4a", "Ostt-recording-x.m4a"]
        for name in foreign { try touch(store, name, created: old) }
        try FileManager.default.createDirectory(at: store.directory.appending(path: "ostt-recording-zz"), withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.creationDate: old], ofItemAtPath: store.directory.appending(path: "ostt-recording-zz").path(percentEncoded: false))

        store.deleteRecordings(olderThan: try #require(RetentionPeriod.threeDays.cutoff(before: now)))

        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path(percentEncoded: false))
        #expect(Set(left) == Set(foreign + [recent, "ostt-recording-zz"]))
    }

    @Test func nameDate() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(RecordingStore.date(fromName: "ostt-recording-20261031-120000-042.m4a", timeZone: utc)
            == Date(timeIntervalSince1970: 1_793_448_000.042))
        #expect(RecordingStore.date(fromName: "notes-20261031-120000-042.m4a", timeZone: utc) == nil)
        #expect(RecordingStore.date(fromName: "ostt-recording-garbage.m4a", timeZone: utc) == nil)
    }

    @Test func unwritableFolderFailsWithItsPath() throws {
        let parent = root.appending(path: "locked", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o500])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path(percentEncoded: false)) }
        let store = RecordingStore(directory: parent.appending(path: "recordings", directoryHint: .isDirectory))

        #expect(throws: RecordingStore.Failure.folderUnavailable(store.directory.path(percentEncoded: false))) {
            try store.newRecordingURL(.m4a)
        }
        #expect(DictationFeedback.failure(RecordingStore.Failure.folderUnavailable("/x")) == .error("Recordings folder unavailable"))
    }
}

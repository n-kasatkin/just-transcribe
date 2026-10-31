import Foundation
import Testing
@testable import JustTranscribeKit

struct RecordingStoreTests {
    private func makeStore() throws -> RecordingStore {
        let root = try Signals.temporaryDirectory()
        return RecordingStore(paths: OsttPaths(
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

    @Test func latestAndPruneTouchOnlyRecordings() throws {
        let store = try makeStore()
        #expect(store.latestRecording() == nil)
        _ = try store.newRecordingURL(.m4a)
        let names = (1...13).map { String(format: "ostt-recording-20261031-1200%02d-000.%@", $0, $0.isMultiple(of: 2) ? "wav" : "m4a") }
        for name in names.shuffled() { touch(store, name) }
        let foreign = ["notes.txt", "my-ostt-recording-1.m4a", "Ostt-recording-x.m4a"]
        for name in foreign { touch(store, name) }
        try FileManager.default.createDirectory(at: store.directory.appending(path: "ostt-recording-zz"), withIntermediateDirectories: true)

        #expect(store.latestRecording()?.lastPathComponent == names.last)
        try store.prune()

        let left = try FileManager.default.contentsOfDirectory(atPath: store.directory.path(percentEncoded: false))
        #expect(Set(left) == Set(names.suffix(10) + foreign + ["ostt-recording-zz"]))
        #expect(store.recordings().map(\.lastPathComponent) == names.suffix(10).reversed())
    }
}

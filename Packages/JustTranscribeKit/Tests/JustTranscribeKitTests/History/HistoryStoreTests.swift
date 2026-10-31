import Foundation
import Testing
@testable import JustTranscribeKit

@MainActor
final class HistoryStoreTests {
    private let root: URL
    private let file: URL

    init() throws {
        root = try Signals.temporaryDirectory()
        file = root.appending(path: "just transcribe/history.json")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    private func date(_ day: Double) -> Date {
        Date(timeIntervalSince1970: 1_793_448_000 + day * 86_400)
    }

    @Test func newestFirstAndPersisted() throws {
        let store = HistoryStore(file: file)
        #expect(store.entries.isEmpty)
        store.add("one", date: date(0))
        store.add("two", date: date(1))
        #expect(store.entries.map(\.text) == ["two", "one"])
        #expect(store.error == nil)

        let reloaded = HistoryStore(file: file)
        #expect(reloaded.entries == store.entries)
    }

    @Test func filesArePrivate() throws {
        HistoryStore(file: file).add("secret", date: date(0))
        #expect(try mode(file) == 0o600)
        #expect(try mode(file.deletingLastPathComponent()) == 0o700)
    }

    @Test func keepsTheNewestUpToCapacity() {
        let store = HistoryStore(file: file)
        for i in 0..<(HistoryStore.capacity + 3) { store.add("\(i)", date: date(Double(i) / 1_000)) }
        #expect(store.entries.count == HistoryStore.capacity)
        #expect(store.entries.first?.text == "\(HistoryStore.capacity + 2)")
        #expect(store.entries.last?.text == "3")
        #expect(HistoryStore(file: file).entries.count == HistoryStore.capacity)
    }

    @Test func removesEntriesOlderThanTheCutoff() {
        let store = HistoryStore(file: file)
        store.add("old", date: date(0))
        store.add("new", date: date(5))
        store.removeOlder(than: date(2))
        #expect(store.entries.map(\.text) == ["new"])
        #expect(HistoryStore(file: file).entries.map(\.text) == ["new"])
    }

    @Test func clearEmptiesTheFileToo() {
        let store = HistoryStore(file: file)
        store.add("one", date: date(0))
        store.clear()
        #expect(store.entries.isEmpty)
        #expect(HistoryStore(file: file).entries.isEmpty)
    }

    @Test func corruptFileIsKeptAsideAndReported() throws {
        let folder = file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{not json".utf8).write(to: file)
        let store = HistoryStore(file: file)
        #expect(store.entries.isEmpty)
        #expect(store.error?.contains("history-unreadable-") == true)
        store.add("fresh", date: date(0))
        #expect(HistoryStore(file: file).entries.map(\.text) == ["fresh"])

        let aside = try FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false))
            .filter { $0.hasPrefix("history-unreadable-") }
        #expect(aside.count == 1)
        #expect(try Data(contentsOf: folder.appending(path: aside[0])) == Data("{not json".utf8))
    }

    @Test func unwritableLocationReportsTheError() throws {
        let blocker = root.appending(path: "blocker")
        try Data().write(to: blocker)
        let store = HistoryStore(file: blocker.appending(path: "history.json"))
        store.add("kept in memory", date: date(0))
        #expect(store.entries.map(\.text) == ["kept in memory"])
        #expect(store.error != nil)
    }

    private func mode(_ url: URL) throws -> Int? {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return (attributes[.posixPermissions] as? NSNumber)?.intValue
    }
}

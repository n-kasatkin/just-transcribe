import AVFoundation
import Testing
@testable import JustTranscribeKit

final class TakeTests {
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

    @Test(arguments: [
        Signals.noise(seconds: 10),
        [Float](repeating: 0, count: 160_000),
        [],
        Signals.noise(seconds: 2) + Signals.tone(seconds: 0.1) + Signals.noise(seconds: 2),
    ])
    func silenceIsNotSaved(samples: [Float]) throws {
        let store = try makeStore()
        #expect(try Take.save(samples, as: .m4a, in: store) == .nothingHeard)
        #expect(store.recordings().isEmpty)
    }

    @Test(arguments: AudioContainer.allCases)
    func speechIsSavedTrimmed(container: AudioContainer) throws {
        let store = try makeStore()
        let samples = Signals.noise(seconds: 2) + Signals.tone(seconds: 1) + Signals.noise(seconds: 2)

        let result = try Take.save(samples, as: container, in: store)

        guard case let .saved(url, duration) = result else {
            Issue.record("expected a saved take, got \(result)")
            return
        }
        #expect(abs(duration - 1.6) < 0.001)
        #expect(url.pathExtension == container.fileExtension)
        #expect(store.latestRecording() == url)
        let file = try AVAudioFile(forReading: url)
        #expect(abs(Double(file.length) / 16_000 - 1.6) < 0.1)
    }

    @Test func failedPruneKeepsTheSavedTake() throws {
        let store = try makeStore()
        let speech = Signals.tone(seconds: 0.5)
        for i in 0..<10 {
            _ = try Take.save(speech, as: .wav, in: store, date: Date(timeIntervalSince1970: 1_793_448_000 + Double(i)))
        }
        // The oldest take is due for pruning but cannot be deleted.
        let oldest = try #require(store.recordings().last)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: oldest.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: oldest.path(percentEncoded: false)) }

        let result = try Take.save(speech, as: .wav, in: store, date: Date(timeIntervalSince1970: 1_793_448_100))

        guard case let .saved(url, _) = result else {
            Issue.record("expected a saved take, got \(result)")
            return
        }
        #expect(store.latestRecording() == url)
    }

    @Test func savingPrunesToTen() throws {
        let store = try makeStore()
        let speech = Signals.tone(seconds: 0.5)
        for i in 0..<12 {
            _ = try Take.save(speech, as: .wav, in: store, date: Date(timeIntervalSince1970: 1_793_448_000 + Double(i)))
        }
        #expect(store.recordings().count == 10)
    }
}

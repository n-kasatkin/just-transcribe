import Foundation
import Testing
@testable import JustTranscribeKit

struct ActiveModelCacheTests {
    /// A fake ostt that counts its runs in `calls` and prints the contents of `model`.
    private func makeFake() throws -> FakeOstt {
        let fake = try FakeOstt(script: "echo x >> \"$(dirname \"$0\")/calls\"; cat \"$(dirname \"$0\")/model\"")
        try Data("whisper/base\n".utf8).write(to: fake.file("model"))
        try Data("[model]\n".utf8).write(to: fake.file("ostt.toml"))
        return fake
    }

    private func calls(_ fake: FakeOstt) throws -> Int {
        try String(contentsOf: fake.file("calls"), encoding: .utf8).split(separator: "\n").count
    }

    private func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path(percentEncoded: false))
    }

    @Test func unchangedConfigIsAnsweredFromCache() async throws {
        let fake = try makeFake()
        defer { fake.remove() }
        let cache = ActiveModelCache(runner: fake.runner, configFile: fake.file("ostt.toml"))
        #expect(try await cache.current() == ActiveModel(providerID: "whisper", modelID: "base"))
        #expect(try await cache.current() == ActiveModel(providerID: "whisper", modelID: "base"))
        #expect(try calls(fake) == 1)
    }

    @Test func changedConfigIsQueriedAgain() async throws {
        let fake = try makeFake()
        defer { fake.remove() }
        let config = fake.file("ostt.toml")
        try touch(config, Date(timeIntervalSince1970: 1_000))
        let cache = ActiveModelCache(runner: fake.runner, configFile: config)
        _ = try await cache.current()
        try Data("No model selected.\n".utf8).write(to: fake.file("model"))
        try touch(config, Date(timeIntervalSince1970: 2_000))
        #expect(try await cache.current() == nil)
        #expect(try calls(fake) == 2)
    }

    @Test func invalidateForcesAQuery() async throws {
        let fake = try makeFake()
        defer { fake.remove() }
        let cache = ActiveModelCache(runner: fake.runner, configFile: fake.file("ostt.toml"))
        _ = try await cache.current()
        try Data("elevenlabs/scribe_v2\n".utf8).write(to: fake.file("model"))
        await cache.invalidate()
        #expect(try await cache.current() == ActiveModel(providerID: "elevenlabs", modelID: "scribe_v2"))
        #expect(try calls(fake) == 2)
    }

    @Test func invalidateDuringAQueryDropsItsAnswer() async throws {
        let fake = try FakeOstt(script: "echo x >> \"$(dirname \"$0\")/calls\"; touch \"$(dirname \"$0\")/started\"; sleep 0.5; echo whisper/base")
        defer { fake.remove() }
        try Data("[model]\n".utf8).write(to: fake.file("ostt.toml"))
        let cache = ActiveModelCache(runner: fake.runner, configFile: fake.file("ostt.toml"))
        async let first = cache.current()
        try await waitForFile(fake.file("started"))
        await cache.invalidate()
        #expect(try await first == ActiveModel(providerID: "whisper", modelID: "base"))
        _ = try await cache.current()
        #expect(try calls(fake) == 2)
    }

    @Test func failuresAreNotCached() async throws {
        let fake = try FakeOstt(script: "echo x >> \"$(dirname \"$0\")/calls\"; echo 'Error: broken' >&2; exit 1")
        defer { fake.remove() }
        let cache = ActiveModelCache(runner: fake.runner, configFile: fake.file("ostt.toml"))
        await #expect(throws: OsttError.self) { try await cache.current() }
        await #expect(throws: OsttError.self) { try await cache.current() }
        #expect(try calls(fake) == 2)
    }
}

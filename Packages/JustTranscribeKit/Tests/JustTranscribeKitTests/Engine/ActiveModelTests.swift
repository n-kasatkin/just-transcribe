import Foundation
import Testing
@testable import JustTranscribeKit

struct ActiveModelTests {
    @Test func noModelSelectedIsNil() throws {
        #expect(try ActiveModel.parse("No model selected.\n") == nil)
    }

    @Test(arguments: [
        ("elevenlabs/scribe_v2\n", "elevenlabs", "scribe_v2", EngineAudioFormat.m4a),
        ("openai/gpt-4o-transcribe\n", "openai", "gpt-4o-transcribe", .m4a),
        ("deepgram/nova-3", "deepgram", "nova-3", .m4a),
        ("whisper/large-v3-turbo-q5_0\n", "whisper", "large-v3-turbo-q5_0", .wav),
        ("parakeet/tdt-0.6b-v3\n", "parakeet", "tdt-0.6b-v3", .wav),
        ("command/my-script\n", "command", "my-script", .wav),
        ("http/org/model:latest\n", "http", "org/model:latest", .m4a),
    ])
    func parsesProviderAndModel(output: String, provider: String, model: String, format: EngineAudioFormat) throws {
        let active = try #require(try ActiveModel.parse(output))
        #expect(active == ActiveModel(providerID: provider, modelID: model))
        #expect(active.audioFormat == format)
    }

    @Test(arguments: ["", "\n", "garbage", "/model", "provider/", "two words/x", "a/b\nc/d"])
    func rejectsUnrecognizedOutput(output: String) {
        #expect(throws: ActiveModel.ParseError.self) { try ActiveModel.parse(output) }
    }

    @Test func currentRunsModelCurrentThroughTheRunner() async throws {
        let fake = try FakeOstt(script: "[ \"$1 $2\" = 'model current' ] && echo 'whisper/base' || exit 2")
        defer { fake.remove() }
        #expect(try await ActiveModel.current(using: fake.runner) == ActiveModel(providerID: "whisper", modelID: "base"))
    }
}

import Foundation
import os
import Testing
@testable import JustTranscribeKit

/// `Tests/Fixtures/model-params.json`, written by `scripts/dump-model-params.sh` from the pinned ostt:
/// every model ostt lists with the params it accepts.
enum ModelParamsFixture {
    struct Entry: Codable {
        struct Param: Codable {
            var name: String
            var type: String
        }
        var provider: String
        var model: String
        var params: [Param]

        var id: OsttModelID { OsttModelID(provider: provider, model: model) }
        /// The entry as `ostt model params MODEL --format json` prints it.
        var json: String { String(decoding: try! JSONEncoder().encode(self), as: UTF8.self) }
    }

    static let file = URL(filePath: #filePath)
        .deletingLastPathComponent() // Settings
        .deletingLastPathComponent() // JustTranscribeKitTests
        .deletingLastPathComponent() // Tests
        .appending(path: "Fixtures/model-params.json")

    static let entries: [Entry] = try! JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))

    static func params(_ id: OsttModelID) throws -> [ModelParam] {
        let entry = try #require(entries.first { $0.id == id })
        return try OsttOutput.modelParams(entry.json)
    }
}

/// Answers `model params` from the fixture and `transcribe` with a transcript, recording every call.
final class FixtureRunner: OsttRunning {
    private let log = OSAllocatedUnfairLock(initialState: [[String]]())

    var calls: [[String]] { log.withLock { $0 } }

    func run(_ arguments: [String], timeout: Duration, onStderr: (@Sendable (String) -> Void)?) async throws -> OsttResult {
        log.withLock { $0.append(arguments) }
        if arguments.starts(with: ["model", "params"]), let id = OsttModelID(arguments[2]),
           let entry = ModelParamsFixture.entries.first(where: { $0.id == id }) {
            guard !entry.params.isEmpty else {
                let stderr = "Error: No params are supported for \(id).\n"
                throw OsttError.failed(OsttResult(exitCode: 1, stdout: "", stderr: stderr))
            }
            return OsttResult(exitCode: 0, stdout: entry.json, stderr: "")
        }
        return OsttResult(exitCode: 0, stdout: "hello\n", stderr: "")
    }
}

struct ProviderParamsTests {
    private let nova3 = OsttModelID(provider: "deepgram", model: "nova-3")

    @Test func fixtureCoversEveryCloudProvider() {
        let providers = Set(ModelParamsFixture.entries.map(\.provider))
        #expect(OsttProvider.cloud.allSatisfy { providers.contains($0.id) })
    }

    @Test(arguments: ModelParamsFixture.entries.map(\.id.description))
    func parsesEveryModelsParams(model: String) throws {
        let id = try #require(OsttModelID(model))
        let entry = try #require(ModelParamsFixture.entries.first { $0.id == id })
        let params = try ModelParamsFixture.params(id)
        #expect(params.map(\.name) == entry.params.map(\.name))
        // A type this list lacks is new in ostt and should get its own kind or be confirmed as free text.
        let known = ["boolean", "number", "integer", "string", "string list",
                     "boolean or string", "boolean or string list", "string or string list"]
        #expect(entry.params.allSatisfy { known.contains($0.type) })
        if OsttProvider.withID(id.provider)?.isLocal == false {
            #expect(!params.isEmpty)
        }
    }

    @Test func kindsFollowOsttTypes() throws {
        let kinds = Dictionary(uniqueKeysWithValues: try ModelParamsFixture.params(nova3).map { ($0.name, $0.kind) })
        #expect(kinds["mip_opt_out"] == .boolean)
        #expect(kinds["utt_split"] == .number)
        #expect(kinds["keyterm"] == .stringList)
        #expect(kinds["language"] == .string)
        #expect(kinds["detect_language"] == .string)
        let scribe = try ModelParamsFixture.params(OsttModelID(provider: "elevenlabs", model: "scribe_v2"))
        #expect(scribe.first { $0.name == "num_speakers" }?.kind == .integer)
    }

    @Test func deepgramArguments() throws {
        let values: [String: ParamValue] = [
            "mip_opt_out": .bool(true), "smart_format": .bool(false), "language": .string("multi"),
            "utt_split": .number(0.8), "keyterm": .stringList(["ostt", "just transcribe"]),
        ]
        #expect(ProviderParams.arguments(values, supported: try ModelParamsFixture.params(nova3)) == [
            "--param", "keyterm=ostt,just transcribe", "--param", "language=multi", "--param", "mip_opt_out=true",
            "--param", "smart_format=false", "--param", "utt_split=0.8",
        ])
    }

    @Test func elevenLabsArguments() throws {
        let values: [String: ParamValue] = [
            "language_code": .string("ru"), "tag_audio_events": .bool(false), "no_verbatim": .bool(true),
            "num_speakers": .integer(2),
        ]
        let supported = try ModelParamsFixture.params(OsttModelID(provider: "elevenlabs", model: "scribe_v2"))
        #expect(ProviderParams.arguments(values, supported: supported) == [
            "--param", "language_code=ru", "--param", "no_verbatim=true", "--param", "num_speakers=2",
            "--param", "tag_audio_events=false",
        ])
    }

    @Test func openAIArgumentsFollowTheModel() throws {
        let values: [String: ParamValue] = ["languages": .stringList(["en", "fr"]), "language": .string("en")]
        let gpt = try ModelParamsFixture.params(OsttModelID(provider: "openai", model: "gpt-transcribe"))
        let whisper = try ModelParamsFixture.params(OsttModelID(provider: "openai", model: "whisper-1"))
        #expect(ProviderParams.arguments(values, supported: gpt) == ["--param", "languages=en,fr"])
        #expect(ProviderParams.arguments(values, supported: whisper) == ["--param", "language=en"])
    }

    @Test func unsupportedParamsAreDroppedOnModelChange() throws {
        let values: [String: ParamValue] = ["keyterm": .stringList(["ostt"]), "mip_opt_out": .bool(true)]
        let nova2 = try ModelParamsFixture.params(OsttModelID(provider: "deepgram", model: "nova-2"))
        #expect(ProviderParams.arguments(values, supported: nova2) == ["--param", "mip_opt_out=true"])
        let scribe1 = try ModelParamsFixture.params(OsttModelID(provider: "elevenlabs", model: "scribe_v1"))
        #expect(ProviderParams.arguments(["no_verbatim": .bool(true)], supported: scribe1).isEmpty)
        #expect(ProviderParams.arguments(["language": .string("en")], supported: []).isEmpty)
    }

    @Test func valuesOfAnotherKindAreDropped() throws {
        let values: [String: ParamValue] = ["utt_split": .string("fast"), "mip_opt_out": .string("true")]
        #expect(ProviderParams.arguments(values, supported: try ModelParamsFixture.params(nova3)).isEmpty)
    }

    @Test func parsesFieldText() throws {
        #expect(try ParamValue.parse("  ", as: .string) == nil)
        #expect(try ParamValue.parse(" en ", as: .string) == .string("en"))
        #expect(try ParamValue.parse("0.25", as: .number) == .number(0.25))
        #expect(try ParamValue.parse("3", as: .integer) == .integer(3))
        #expect(try ParamValue.parse("true", as: .boolean) == .bool(true))
        #expect(try ParamValue.parse("ostt, just transcribe,, ", as: .stringList) == .stringList(["ostt", "just transcribe"]))
        #expect(try ParamValue.parse(" , ", as: .stringList) == nil)
        #expect(throws: ParamValue.InputError.notANumber) { try ParamValue.parse("fast", as: .number) }
        #expect(throws: ParamValue.InputError.notANumber) { try ParamValue.parse("inf", as: .number) }
        #expect(throws: ParamValue.InputError.notAnInteger) { try ParamValue.parse("2.5", as: .integer) }
        #expect(throws: ParamValue.InputError.notABoolean) { try ParamValue.parse("yes", as: .boolean) }
        #expect(ParamValue.stringList(["a", "b"]).text == "a, b")
        #expect(ParamValue.number(1).argument == "1.0")
    }

    @Test func curatedParamsComeFirst() throws {
        let (curated, more) = ProviderParams.split(try ModelParamsFixture.params(nova3))
        #expect(curated.map(\.param.name) == ["language", "smart_format", "punctuate", "filler_words", "mip_opt_out"])
        #expect(curated.last?.label == "Opt out of model training")
        #expect(more.count == 33 - 5)
        #expect(!more.contains { $0.name == "mip_opt_out" })
        let scribe = ProviderParams.split(try ModelParamsFixture.params(OsttModelID(provider: "elevenlabs", model: "scribe_v2")))
        #expect(scribe.curated.map(\.param.name) == ["language_code", "tag_audio_events", "no_verbatim"])
    }

    @Test func modelParamArgumentsAskOsttOncePerModel() async throws {
        let runner = FixtureRunner()
        let arguments = ModelParamArguments(client: OsttSettingsClient(runner: runner)) {
            $0 == "deepgram" ? ["mip_opt_out": .bool(true)] : [:]
        }
        let nova3 = ActiveModel(providerID: "deepgram", modelID: "nova-3")
        #expect(try await arguments.arguments(for: nova3) == ["--param", "mip_opt_out=true"])
        #expect(try await arguments.arguments(for: nova3) == ["--param", "mip_opt_out=true"])
        #expect(try await arguments.arguments(for: ActiveModel(providerID: "groq", modelID: "whisper-large-v3")).isEmpty)
        #expect(runner.calls == [["model", "params", "deepgram/nova-3", "--format", "json"]])
    }

    @Test func modelWithoutParamsGetsNone() async throws {
        let arguments = ModelParamArguments(client: OsttSettingsClient(runner: FixtureRunner())) { _ in
            ["language": .string("en")]
        }
        #expect(try await arguments.arguments(for: ActiveModel(providerID: "parakeet", modelID: "parakeet-ultra")).isEmpty)
        #expect(try await arguments.arguments(for: ActiveModel(providerID: "whisper", modelID: "turbo"))
            == ["--param", "language=en"])
    }
}

final class ProviderParamsPreferencesTests {
    private let suite = "ProviderParamsPreferencesTests-\(UUID().uuidString)"
    private let preferences: AppPreferences

    init() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "jt-params-\(UUID().uuidString)")
        preferences = AppPreferences(defaults: try #require(UserDefaults(suiteName: suite)),
                                     paths: OsttPaths(configDirectory: root, dataDirectory: root))
    }

    deinit {
        preferences.defaults.removePersistentDomain(forName: suite)
    }

    @Test func deepgramOptsOutOfTrainingByDefault() {
        #expect(preferences.providerParams("deepgram") == ["mip_opt_out": .bool(true)])
        #expect(preferences.providerParams("elevenlabs").isEmpty)
    }

    @Test func storedValuesReplaceDefaultsUntilReset() {
        preferences.setProviderParams(["mip_opt_out": .bool(false), "language": .string("ru")], for: "deepgram")
        preferences.setProviderParams(["no_verbatim": .bool(true)], for: "elevenlabs")
        #expect(preferences.providerParams("deepgram") == ["mip_opt_out": .bool(false), "language": .string("ru")])
        preferences.setProviderParams([:], for: "deepgram")
        #expect(preferences.providerParams("deepgram").isEmpty)
        preferences.resetProviderParams("deepgram")
        #expect(preferences.providerParams("deepgram") == ["mip_opt_out": .bool(true)])
        #expect(preferences.providerParams("elevenlabs") == ["no_verbatim": .bool(true)])
    }
}

/// Runs `transcribe` on the real `vendor/ostt/ostt` in a throwaway home with no keys, so nothing is
/// sent: ostt checks `--param` names and values first and then stops at "No API key", which proves it
/// accepted them.
private let vendorOstt = ModelParamsFixture.file
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent() // JustTranscribeKit
    .deletingLastPathComponent().deletingLastPathComponent() // repo root
    .appending(path: "vendor/ostt/ostt")

@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: vendorOstt.path(percentEncoded: false)),
                "needs vendor/ostt/ostt from scripts/fetch-ostt.sh"),
       .timeLimit(.minutes(1)))
struct OsttParamValidationTests {

    static let cloudModels = ModelParamsFixture.entries
        .filter { entry in OsttProvider.cloud.contains { $0.id == entry.provider } }
        .map(\.id.description)

    private static func sample(_ kind: ModelParam.Kind) -> ParamValue {
        switch kind {
        case .boolean: .bool(true)
        case .number: .number(0.5)
        case .integer: .integer(1)
        case .string: .string("en")
        case .stringList: .stringList(["en", "fr"])
        }
    }

    @Test(arguments: cloudModels)
    func acceptsCuratedParamsAndDefaults(model: String) throws {
        let id = try #require(OsttModelID(model))
        let supported = try ModelParamsFixture.params(id)
        var values = Dictionary(uniqueKeysWithValues: ProviderParams.split(supported).curated.map {
            ($0.param.name, Self.sample($0.param.kind))
        })
        values.merge(ProviderParams.defaults[id.provider] ?? [:]) { $1 }
        let arguments = ProviderParams.arguments(values, supported: supported)
        #expect(!arguments.isEmpty)

        let home = FileManager.default.temporaryDirectory.appending(path: "jt-validate-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let audio = home.appending(path: "take.m4a")
        try Data().write(to: audio)

        let process = Process()
        process.executableURL = vendorOstt
        process.arguments = ["transcribe", audio.path(percentEncoded: false), "-m", model] + arguments
        process.environment = isolatedEnvironment(in: home).merging(["PATH": "/usr/bin:/bin"]) { $1 }
        let stderr = Pipe()
        process.standardError = stderr
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(output.contains("No API key for"), "\(arguments): \(output)")
    }

    @Test(arguments: [
        ("openai/whisper-1", "temperature", ParamValue.number(5), "Expected 0-1"),
        ("elevenlabs/scribe_v2", "timestamps_granularity", .string("bogus"), "Expected one of"),
        ("elevenlabs/scribe_v2", "seed", .integer(-1), "Expected 0-"),
        ("whisper/base", "temperature", .number(5), "Expected 0-1"),
    ])
    func validatorRejectsValuesOsttRejects(model: String, name: String, value: ParamValue, expected: String) async throws {
        let message = try await OsttParamValidator(executableURL: vendorOstt).rejection(name, value, model: try #require(OsttModelID(model)))
        #expect(message?.hasPrefix("Invalid value for param '\(name)'") == true)
        #expect(message?.contains(expected) == true, "\(message ?? "nil")")
    }

    @Test(arguments: [
        ("openai/whisper-1", "temperature", ParamValue.number(0.5)),
        ("deepgram/nova-3", "mip_opt_out", .bool(true)),
        ("elevenlabs/scribe_v2", "timestamps_granularity", .string("word")),
        ("whisper/base", "language", .string("en")),
    ])
    func validatorAcceptsValuesOsttAccepts(model: String, name: String, value: ParamValue) async throws {
        let message = try await OsttParamValidator(executableURL: vendorOstt).rejection(name, value, model: try #require(OsttModelID(model)))
        #expect(message == nil)
    }
}

@Test func validatorReadsOnlyParamErrors() {
    #expect(OsttParamValidator.rejection(in: "Error: Invalid value for param 'seed' in 'elevenlabs/scribe_v2'. Expected 0-2147483647.\n")
            == "Invalid value for param 'seed' in 'elevenlabs/scribe_v2'. Expected 0-2147483647.")
    #expect(OsttParamValidator.rejection(in: "Error: Invalid param 'bogus' for 'deepgram/nova-3'.") == "Invalid param 'bogus' for 'deepgram/nova-3'.")
    #expect(OsttParamValidator.rejection(in: "Error: No API key for Deepgram. Run 'ostt auth' to add an API key.") == nil)
}

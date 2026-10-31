import Foundation
import Testing
@testable import JustTranscribeKit

/// Fixtures follow what ostt 0.0.34 prints (`serde_json::to_string_pretty`, keys sorted).
struct OsttOutputTests {
    static let cloudList = """
        [
          {
            "active": false,
            "installed": null,
            "model": "scribe_v2",
            "name": "Scribe v2 (general purpose)",
            "provider": "elevenlabs"
          },
          {
            "active": true,
            "installed": null,
            "model": "scribe_v1",
            "name": "Scribe v1 (legacy)",
            "provider": "elevenlabs"
          }
        ]
        """

    static let whisperList = """
        [
          {
            "active": false,
            "installed": false,
            "model": "large-v3-turbo",
            "name": "Whisper Large v3 Turbo",
            "provider": "whisper"
          },
          {
            "active": true,
            "installed": true,
            "model": "large-v3-turbo-q5_0",
            "name": "Whisper Large v3 Turbo (Q5_0)",
            "provider": "whisper"
          },
          {
            "active": false,
            "installed": false,
            "model": "my-custom",
            "name": "My custom",
            "provider": "whisper"
          }
        ]
        """

    @Test func parsesCloudModelList() throws {
        let models = try OsttOutput.models(Self.cloudList)
        #expect(models == [
            OsttModel(id: OsttModelID(provider: "elevenlabs", model: "scribe_v2"), name: "Scribe v2 (general purpose)",
                      installed: nil, active: false),
            OsttModel(id: OsttModelID(provider: "elevenlabs", model: "scribe_v1"), name: "Scribe v1 (legacy)",
                      installed: nil, active: true),
        ])
    }

    @Test func parsesLocalModelList() throws {
        let models = try OsttOutput.models(Self.whisperList)
        #expect(models.map(\.installed) == [false, true, false])
        #expect(models.map(\.active) == [false, true, false])
        #expect(models[1].id.description == "whisper/large-v3-turbo-q5_0")
        #expect(try OsttOutput.models("[]") == [])
    }

    @Test func rejectsUnexpectedOutput() {
        #expect(throws: OsttSettingsError.unexpectedOutput("Error: boom")) { try OsttOutput.models("Error: boom") }
        #expect(throws: OsttSettingsError.self) { try OsttOutput.models(#"[{"model": "x"}]"#) }
    }

    @Test func parsesStringArrays() throws {
        #expect(try OsttOutput.strings("[\n  \"-foo\",\n  \"Привет \\\"q\\\"\"\n]\n") == ["-foo", "Привет \"q\""])
        #expect(try OsttOutput.strings("[]\n") == [])
    }

    @Test func parsesCurrentModel() {
        #expect(OsttOutput.currentModel("elevenlabs/scribe_v2\n") == OsttModelID(provider: "elevenlabs", model: "scribe_v2"))
        #expect(OsttOutput.currentModel("http/org/model\n") == OsttModelID(provider: "http", model: "org/model"))
        #expect(OsttOutput.currentModel("No model selected.\n") == nil)
    }

    @Test func picksQuantizedLargeV3TurboAsRecommended() throws {
        let models = try OsttOutput.models(Self.whisperList)
        #expect(OsttModel.recommended(in: models) == OsttModelID(provider: "whisper", model: "large-v3-turbo-q5_0"))
        #expect(OsttModel.recommended(in: Array(models.prefix(1))) == nil)
        let parakeet = OsttModel(id: OsttModelID(provider: "parakeet", model: "large-v3-turbo-q8"), name: "", installed: false, active: false)
        #expect(OsttModel.recommended(in: [parakeet]) == nil)
    }

    @Test func readsSizesFromRegistryCacheAndCustomModels() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "jt-models-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("""
            [
              {
                "id": "large-v3-turbo-q5_0",
                "provider_id": "whisper",
                "name": "Whisper Large v3 Turbo (Q5_0)",
                "description": "Quantized turbo",
                "languages": ["multilingual"],
                "size_mb": 547,
                "url": "https://huggingface.co/example/ggml-large-v3-turbo-q5_0.bin",
                "recommended_hardware": null,
                "sha256": "00",
                "category": "whisper",
                "group_id": "large-v3-turbo"
              },
              {
                "id": "base",
                "name": "Whisper Base",
                "description": "",
                "languages": [],
                "size_mb": 142,
                "url": "https://huggingface.co/example/ggml-base.bin",
                "recommended_hardware": null,
                "sha256": null,
                "category": null
              }
            ]
            """.utf8).write(to: dir.appending(path: "registry.json"))
        try Data("""
            {"version": 1, "custom_models": [{"id": "tdt", "provider_id": "parakeet", "name": "TDT", "description": "",
              "languages": [], "size_mb": 600, "url": "https://example.com/tdt.gguf", "recommended_hardware": null,
              "sha256": null, "category": null, "group_id": null}]}
            """.utf8).write(to: dir.appending(path: "models.json"))

        #expect(OsttOutput.localModelSizes(in: dir) == [
            OsttModelID(provider: "whisper", model: "large-v3-turbo-q5_0"): 547,
            OsttModelID(provider: "whisper", model: "base"): 142,
            OsttModelID(provider: "parakeet", model: "tdt"): 600,
        ])
        #expect(OsttOutput.localModelSizes(in: dir.appending(path: "missing")) == [:])
    }
}

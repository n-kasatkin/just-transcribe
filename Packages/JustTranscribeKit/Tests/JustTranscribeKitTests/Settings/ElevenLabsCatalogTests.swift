import Foundation
import Testing
@testable import JustTranscribeKit

/// Rows shaped like ElevenLabs' `GET /v1/models` response.
struct ElevenLabsCatalogTests {
    static let response = """
        [
          {"model_id": "eleven_v3", "name": "Eleven v3", "can_do_text_to_speech": true,
           "can_do_voice_conversion": false,
           "model_rates": {"character_cost_multiplier": 1.0, "cost_discount_multiplier": 0.5}},
          {"model_id": "eleven_multilingual_sts_v2", "name": "Multilingual STS v2",
           "can_do_text_to_speech": false, "can_do_voice_conversion": true},
          {"model_id": "scribe_v3", "name": "Scribe v3"}
        ]
        """

    @Test func decodeClassifiesInputOutputAndPrice() throws {
        let models = try ElevenLabsCatalog.decode(Data(Self.response.utf8))
        #expect(models.map(\.inputs) == [[.text], [.audio], [.audio]])
        #expect(models.map(\.outputs) == [[.audio], [.audio], [.text]])
        #expect(models.map(\.creditsPerCharacter) == [0.5, nil, nil])
    }

    @Test func decodeRejectsUnexpectedJSON() {
        #expect(throws: ElevenLabsCatalogError.unreadable) {
            try ElevenLabsCatalog.decode(Data(#"{"detail": "nope"}"#.utf8))
        }
    }

    @Test func mergeAllowsOnlyOsttModels() throws {
        let ostt = [OsttModel(id: OsttModelID(provider: "elevenlabs", model: "scribe_v2"), name: "Scribe v2",
                              installed: nil, active: true)]
        let merged = ElevenLabsCatalog.merge(ostt: ostt, remote: try ElevenLabsCatalog.decode(Data(Self.response.utf8)))
        #expect(merged.map(\.id) == ["scribe_v2", "eleven_v3", "eleven_multilingual_sts_v2", "scribe_v3"])
        #expect(merged.map(\.selectable) == [true, false, false, false])
    }
}

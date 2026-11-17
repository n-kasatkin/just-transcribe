import Foundation

/// What a model takes in or gives back.
public enum Modality: String, Sendable, Hashable, Comparable {
    case text, audio

    public static func < (lhs: Modality, rhs: Modality) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// One model as the model picker shows it: what it does, what it costs, and whether ostt can transcribe with it.
public struct CatalogModel: Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var inputs: Set<Modality>
    public var outputs: Set<Modality>
    /// ElevenLabs credits per character (`model_rates`), discount applied; nil when the API does not report one.
    public var creditsPerCharacter: Double?
    /// ostt lists this model, so it can be selected for dictation.
    public var selectable: Bool

    public init(id: String, name: String, inputs: Set<Modality>, outputs: Set<Modality>,
                creditsPerCharacter: Double? = nil, selectable: Bool = false) {
        self.id = id
        self.name = name
        self.inputs = inputs
        self.outputs = outputs
        self.creditsPerCharacter = creditsPerCharacter
        self.selectable = selectable
    }
}

public enum ElevenLabsCatalogError: Error, Equatable, Sendable {
    /// The API refused the request; carries its `detail.message` or the HTTP status.
    case rejected(String)
    case unreadable
}

/// The live model list of ElevenLabs (`GET /v1/models`), merged with the Scribe models ostt can use.
public enum ElevenLabsCatalog {
    public static let providerID = "elevenlabs"
    public static let endpoint = URL(string: "https://api.elevenlabs.io/v1/models")!

    public static func fetch(apiKey: String, session: URLSession = .shared) async throws -> [CatalogModel] {
        var request = URLRequest(url: endpoint, timeoutInterval: 20)
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            struct Failure: Decodable {
                struct Detail: Decodable { var message: String }
                var detail: Detail
            }
            let message = try? JSONDecoder().decode(Failure.self, from: data).detail.message
            throw ElevenLabsCatalogError.rejected(message ?? "ElevenLabs answered HTTP \(status).")
        }
        return try decode(data)
    }

    private struct Row: Decodable {
        struct Rates: Decodable {
            var character_cost_multiplier: Double?
            var cost_discount_multiplier: Double?
        }
        var model_id: String
        var name: String?
        var can_do_text_to_speech: Bool?
        var can_do_voice_conversion: Bool?
        var model_rates: Rates?
    }

    /// Text-to-speech is text → audio, voice conversion audio → audio. The API has no speech-to-text flag,
    /// so a `scribe` model is read as audio → text.
    static func decode(_ data: Data) throws -> [CatalogModel] {
        guard let rows = try? JSONDecoder().decode([Row].self, from: data) else { throw ElevenLabsCatalogError.unreadable }
        return rows.map { row in
            var inputs: Set<Modality> = []
            var outputs: Set<Modality> = []
            if row.can_do_text_to_speech == true { inputs.insert(.text); outputs.insert(.audio) }
            if row.can_do_voice_conversion == true { inputs.insert(.audio); outputs.insert(.audio) }
            if row.model_id.hasPrefix("scribe") { inputs.insert(.audio); outputs.insert(.text) }
            let credits = row.model_rates.flatMap { rates in
                rates.character_cost_multiplier.map { $0 * (rates.cost_discount_multiplier ?? 1) }
            }
            return CatalogModel(id: row.model_id, name: row.name ?? row.model_id,
                                inputs: inputs, outputs: outputs, creditsPerCharacter: credits)
        }
    }

    /// ostt's models first, in its order and with its names, then every other API model. Only ostt's
    /// models are selectable: ostt refuses any other id.
    public static func merge(ostt: [OsttModel], remote: [CatalogModel]) -> [CatalogModel] {
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let known = ostt.map { model in
            CatalogModel(id: model.id.model, name: model.name, inputs: [.audio], outputs: [.text],
                         creditsPerCharacter: byID[model.id.model]?.creditsPerCharacter, selectable: true)
        }
        let ids = Set(known.map(\.id))
        return known + remote.filter { !ids.contains($0.id) }
    }
}

/// A transcription provider the settings offer, with ostt's id and display name
/// (`src/transcription/provider.rs`).
public struct OsttProvider: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    /// Runs on this Mac from a downloaded model; otherwise a cloud provider that needs an API key.
    public let isLocal: Bool

    public var needsKey: Bool { !isLocal }

    /// Cloud providers with an API key, in ostt's order.
    public static let cloud: [OsttProvider] = [
        ("openai", "OpenAI"), ("deepgram", "Deepgram"), ("deepinfra", "DeepInfra"), ("groq", "Groq"),
        ("assemblyai", "AssemblyAI"), ("berget", "Berget"), ("elevenlabs", "ElevenLabs"), ("mistral", "Mistral"),
    ].map { OsttProvider(id: $0, name: $1, isLocal: false) }

    /// Offline engines whose models download from ostt's registry.
    public static let local: [OsttProvider] = [
        OsttProvider(id: "whisper", name: "Whisper (local)", isLocal: true),
        OsttProvider(id: "parakeet", name: "Parakeet (local)", isLocal: true),
    ]

    public static let all = cloud + local

    public static func withID(_ id: String) -> OsttProvider? {
        all.first { $0.id == id }
    }
}

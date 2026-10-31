import Foundation

/// A model as ostt names it on the command line: `provider/model`.
public struct OsttModelID: Sendable, Hashable, CustomStringConvertible {
    public var provider: String
    public var model: String

    public init(provider: String, model: String) {
        self.provider = provider
        self.model = model
    }

    /// Splits `provider/model` at the first slash, as ostt's `parse_provider_model` does.
    public init?(_ text: String) {
        let parts = text.split(separator: "/", maxSplits: 1)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        self.init(provider: String(parts[0]), model: String(parts[1]))
    }

    public var description: String { "\(provider)/\(model)" }
}

/// One row of `ostt model list --format json` (`src/commands/model.rs`).
public struct OsttModel: Sendable, Hashable, Identifiable {
    public var id: OsttModelID
    public var name: String
    /// Whether a local model's file is downloaded; nil for cloud and external models.
    public var installed: Bool?
    /// The model `ostt model select` last chose.
    public var active: Bool
    /// Download size from ostt's registry cache; nil when unknown.
    public var sizeMB: Int?

    public init(id: OsttModelID, name: String, installed: Bool?, active: Bool, sizeMB: Int? = nil) {
        self.id = id
        self.name = name
        self.installed = installed
        self.active = active
        self.sizeMB = sizeMB
    }

    /// ostt's registry id (`ostt-models/models-v2.json`) of the model recommended for mixed-language dictation.
    public static let recommendedID = OsttModelID(provider: "whisper", model: "turbo-q5_0")

    /// `recommendedID` when listed, else the first quantized Whisper Large v3 Turbo, matched on id and
    /// name with spaces and `_` read as `-`, in case the registry renames it.
    public static func recommended(in models: [OsttModel]) -> OsttModelID? {
        if models.contains(where: { $0.id == recommendedID }) { return recommendedID }
        return models.first { model in
            guard model.id.provider == "whisper" else { return false }
            let text = "\(model.id.model) \(model.name)".lowercased()
                .replacing(" ", with: "-").replacing("_", with: "-")
            return text.contains("turbo") && !text.contains("distil") && text.contains(/(^|[-(])q\d/)
        }?.id
    }
}

/// Parsers for ostt's machine-readable output.
enum OsttOutput {
    private struct Row: Decodable {
        var provider: String
        var model: String
        var name: String
        var installed: Bool?
        var active: Bool
    }

    static func models(_ json: String) throws -> [OsttModel] {
        try decode([Row].self, json).map {
            OsttModel(id: OsttModelID(provider: $0.provider, model: $0.model),
                      name: $0.name, installed: $0.installed, active: $0.active)
        }
    }

    /// `keyword list --format json` and `auth list --format json` both print a string array.
    static func strings(_ json: String) throws -> [String] {
        try decode([String].self, json)
    }

    /// `model current` prints `provider/model`, or "No model selected." on a fresh config.
    static func currentModel(_ stdout: String) -> OsttModelID? {
        OsttModelID(stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// `--version` prints `ostt 0.0.34` (clap's default).
    static func version(_ stdout: String) throws -> String {
        let words = stdout.split(whereSeparator: \.isWhitespace)
        guard words.count == 2, words[0] == "ostt" else {
            throw OsttSettingsError.unexpectedOutput(String(stdout.prefix(200)))
        }
        return String(words[1])
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: Data(json.utf8))
        } catch {
            throw OsttSettingsError.unexpectedOutput(String(json.prefix(200)))
        }
    }

    private struct RegistryEntry: Decodable {
        var id: String
        // Absent in older registry entries, which were all Whisper (`default_local_provider_id`).
        var provider_id: String?
        var size_mb: Int
    }

    private struct LocalState: Decodable {
        var custom_models: [RegistryEntry]?
    }

    /// Download sizes from ostt's cached registry (`models/registry.json`, refreshed by every local
    /// `model list`) and its custom models (`models/models.json`). Unreadable files add nothing.
    static func localModelSizes(in modelsDirectory: URL) -> [OsttModelID: Int] {
        let read = { (name: String) in try? Data(contentsOf: modelsDirectory.appending(path: name)) }
        let registry = read("registry.json").flatMap { try? JSONDecoder().decode([RegistryEntry].self, from: $0) } ?? []
        let custom = read("models.json").flatMap { try? JSONDecoder().decode(LocalState.self, from: $0) }?.custom_models ?? []
        var sizes: [OsttModelID: Int] = [:]
        for entry in registry + custom where entry.size_mb > 0 {
            sizes[OsttModelID(provider: entry.provider_id ?? "whisper", model: entry.id)] = entry.size_mb
        }
        return sizes
    }
}

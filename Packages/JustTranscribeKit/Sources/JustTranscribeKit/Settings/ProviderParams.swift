import Foundation

/// A request param one ostt model accepts, from `ostt model params MODEL --format json`.
public struct ModelParam: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case boolean, number, integer, string, stringList

        /// ostt's type names; the union types ("boolean or string list" and the like) are free text,
        /// passed as typed.
        public init(osttType: String) {
            switch osttType {
            case "boolean": self = .boolean
            case "number": self = .number
            case "integer": self = .integer
            case "string list": self = .stringList
            default: self = .string
            }
        }
    }

    public var name: String
    public var kind: Kind

    public var id: String { name }

    public init(name: String, kind: Kind) {
        self.name = name
        self.kind = kind
    }
}

/// A value the user set for a provider param.
public enum ParamValue: Codable, Sendable, Hashable {
    case bool(Bool)
    case number(Double)
    case integer(Int)
    case string(String)
    case stringList([String])

    public enum InputError: Error, Sendable, Equatable {
        case notABoolean
        case notANumber
        case notAnInteger
    }

    public var kind: ModelParam.Kind {
        switch self {
        case .bool: .boolean
        case .number: .number
        case .integer: .integer
        case .string: .string
        case .stringList: .stringList
        }
    }

    /// The value as `--param key=value` takes it. ostt parses booleans as lowercase `true`/`false`
    /// only, numbers and integers with Rust's float and integer parsers, and lists comma-separated.
    public var argument: String {
        switch self {
        case .bool(let value): value ? "true" : "false"
        case .number(let value): String(value)
        case .integer(let value): String(value)
        case .string(let value): value
        case .stringList(let values): values.joined(separator: ",")
        }
    }

    /// What a text field shows: the argument, with list items separated by ", ".
    public var text: String {
        if case .stringList(let values) = self { return values.joined(separator: ", ") }
        return argument
    }

    /// A text field's contents as a value of `kind`; nil when the field is empty, which leaves the param
    /// unset (ostt rejects empty strings).
    public static func parse(_ text: String, as kind: ModelParam.Kind) throws(InputError) -> ParamValue? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        switch kind {
        case .boolean:
            guard let value = Bool(text) else { throw .notABoolean }
            return .bool(value)
        case .string:
            return .string(text)
        case .number:
            guard let value = Double(text), value.isFinite else { throw .notANumber }
            return .number(value)
        case .integer:
            guard let value = Int(text) else { throw .notAnInteger }
            return .integer(value)
        case .stringList:
            let items = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            return items.isEmpty ? nil : .stringList(items)
        }
    }
}

/// The app's per-provider request params, sent as `--param key=value` with every transcription.
/// ostt.toml is never edited, so the CLI's own `[provider.params]` stay as they are.
public enum ProviderParams {
    /// Values a provider starts with until the user changes any of its params.
    /// Deepgram: opt out of its Model Improvement Program, which otherwise may train on the audio.
    public static let defaults: [String: [String: ParamValue]] = ["deepgram": ["mip_opt_out": .bool(true)]]

    /// Params worth having at hand for dictation, in display order, with their labels. A model shows
    /// those it lists; the rest go under "More options".
    public static let curated: KeyValuePairs<String, String> = [
        "language": "Language",
        "languages": "Languages",
        "language_code": "Language",
        "smart_format": "Smart formatting",
        "punctuate": "Punctuation",
        "filler_words": "Filler words",
        "tag_audio_events": "Tag audio events",
        "no_verbatim": "Remove filler words",
        "mip_opt_out": "Opt out of model training",
    ]

    /// The curated params `params` lists, in `curated` order, and the others in ostt's order.
    public static func split(_ params: [ModelParam]) -> (curated: [(param: ModelParam, label: String)], more: [ModelParam]) {
        let curatedParams = curated.compactMap { name, label in
            params.first { $0.name == name }.map { (param: $0, label: label) }
        }
        let curatedNames = Set(curatedParams.map(\.param.name))
        return (curatedParams, params.filter { !curatedNames.contains($0.name) })
    }

    /// `--param key=value` pairs for the values the model lists with the same kind, sorted by name.
    /// Values for params the model does not take are left out, so a model change never fails a take.
    public static func arguments(_ values: [String: ParamValue], supported: [ModelParam]) -> [String] {
        let kinds = Dictionary(supported.map { ($0.name, $0.kind) }, uniquingKeysWith: { first, _ in first })
        return values.keys.sorted().flatMap { name -> [String] in
            guard let value = values[name], kinds[name] == value.kind else { return [] }
            return ["--param", "\(name)=\(value.argument)"]
        }
    }
}

/// The `--param` arguments for the model a take runs on: the stored values for its provider, kept to
/// the params ostt lists for that model. Each model's list is asked once, since it is fixed per ostt build.
public actor ModelParamArguments {
    private let client: OsttSettingsClient
    private let values: @Sendable (String) -> [String: ParamValue]
    private var supported: [OsttModelID: [ModelParam]] = [:]

    /// - Parameter values: the current values for a provider id, read at each take.
    public init(client: OsttSettingsClient, values: @escaping @Sendable (String) -> [String: ParamValue]) {
        self.client = client
        self.values = values
    }

    public func arguments(for model: ActiveModel) async throws -> [String] {
        let values = values(model.providerID)
        // A provider with nothing set costs no ostt launch.
        guard !values.isEmpty else { return [] }
        let id = OsttModelID(provider: model.providerID, model: model.modelID)
        let params: [ModelParam]
        if let cached = supported[id] {
            params = cached
        } else {
            params = try await client.modelParams(id)
            supported[id] = params
        }
        return ProviderParams.arguments(values, supported: params)
    }
}

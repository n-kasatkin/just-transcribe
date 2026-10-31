import JustTranscribeKit
import SwiftUI

/// The request params one model takes, generated from `ostt model params`: the curated ones first,
/// the rest under "More options". Values are stored per provider and sent with every transcription.
struct ProviderOptionsSection: View {
    let model: SettingsModel
    let id: OsttModelID
    let modelName: String
    @State private var showsMore = false
    /// Bumped by Reset to Defaults, so every row starts over from the stored values.
    @State private var resets = 0

    private var provider: OsttProvider? { OsttProvider.withID(id.provider) }
    private var providerName: String { provider?.name ?? id.provider }
    private var isLocal: Bool { provider?.isLocal == true }
    /// What an unset option is called: for a cloud model, "Default" could be read as the app's defaults.
    private var defaultLabel: String { isLocal ? "Default" : "Provider default" }

    var body: some View {
        Section {
            switch model.modelParams[id] ?? .idle {
            case .idle, .loading:
                ProgressView().controlSize(.small)
                    .task(id: id) { await model.loadModelParams(id) }
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(.red)
                    Spacer()
                    Button("Retry") { Task { await model.loadModelParams(id) } }
                }
            case .loaded(let params) where params.isEmpty:
                Text("This model takes no options.").foregroundStyle(.secondary)
            case .loaded(let params):
                let (curated, more) = ProviderParams.split(params)
                Group {
                    ForEach(curated, id: \.param) { item in
                        ParamRow(model: model, id: id, param: item.param, label: item.label, defaultLabel: defaultLabel)
                    }
                    if !more.isEmpty {
                        DisclosureGroup("More options", isExpanded: $showsMore) {
                            ForEach(more) { param in
                                ParamRow(model: model, id: id, param: param, label: param.name, defaultLabel: defaultLabel)
                            }
                        }
                    }
                }
                .id(resets)
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        model.resetParams(provider: id.provider)
                        resets += 1
                    }
                    .disabled(model.params(for: id.provider) == ProviderParams.defaults[id.provider] ?? [:])
                }
            }
        } header: {
            Text(isLocal ? "Model options" : "Provider options")
        } footer: {
            Text(footer)
        }
    }

    private var footer: String {
        if isLocal {
            return "Options for \(modelName), used on this Mac. Default leaves ostt's own setting."
        }
        let sent = "Options for \(modelName), sent to \(providerName) with each transcription. Provider default leaves the provider's own setting."
        let training = switch id.provider {
        case "deepgram":
            "Opting out of model training is on by default, so Deepgram doesn't use your audio to improve its models."
        case "elevenlabs":
            "ElevenLabs has no training opt-out here: its zero-retention mode is for enterprise accounts and ostt doesn't send it."
        default:
            "ostt has no training opt-out for \(providerName); \(providerName)'s privacy policy says how it uses audio."
        }
        return "\(sent) \(training)"
    }
}

/// One param: a picker for a boolean, a text field otherwise. A field saves a value once typing pauses
/// and ostt accepts it for the model; an empty field unsets the param.
private struct ParamRow: View {
    let model: SettingsModel
    let id: OsttModelID
    let param: ModelParam
    let label: String
    let defaultLabel: String
    @State private var draft: String
    @State private var error: String?

    init(model: SettingsModel, id: OsttModelID, param: ModelParam, label: String, defaultLabel: String) {
        self.model = model
        self.id = id
        self.param = param
        self.label = label
        self.defaultLabel = defaultLabel
        _draft = State(initialValue: model.params(for: id.provider)[param.name]?.text ?? "")
    }

    private var value: ParamValue? { model.params(for: id.provider)[param.name] }

    var body: some View {
        if param.kind == .boolean {
            Picker(label, selection: Binding<Bool?>(
                get: { if case .bool(let on) = value { on } else { nil } },
                set: { model.setParam(param.name, to: $0.map(ParamValue.bool), provider: id.provider) }
            )) {
                Text(defaultLabel).tag(Bool?.none)
                Text("On").tag(Bool?.some(true))
                Text("Off").tag(Bool?.some(false))
            }
        } else {
            VStack(alignment: .leading, spacing: 4) {
                TextField(label, text: $draft, prompt: Text(prompt))
                if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            .task(id: draft) { await commit() }
        }
    }

    private var prompt: String {
        switch param.kind {
        case .number: "Number"
        case .integer: "Whole number"
        case .stringList: "Comma-separated"
        case .boolean, .string: defaultLabel
        }
    }

    /// ostt checks ranges and allowed values only at transcription, so each new value is run past it
    /// first. A rejected value unsets the param rather than leaving the previous one in effect unseen.
    private func commit() async {
        guard (try? await Task.sleep(for: .milliseconds(400))) != nil else { return }
        let parsed: ParamValue?
        do {
            parsed = try ParamValue.parse(draft, as: param.kind)
        } catch let inputError {
            reject(message(inputError))
            return
        }
        guard parsed != value else {
            error = nil
            return
        }
        var rejection: String?
        if let parsed { rejection = await model.paramRejection(param.name, parsed, model: id) }
        guard !Task.isCancelled else { return }
        if let rejection {
            reject(rejection)
        } else {
            error = nil
            model.setParam(param.name, to: parsed, provider: id.provider)
        }
    }

    private func reject(_ message: String) {
        error = "\(message) Not sent until fixed."
        if value != nil { model.setParam(param.name, to: nil, provider: id.provider) }
    }

    private func message(_ error: ParamValue.InputError) -> String {
        switch error {
        case .notABoolean: "Enter true or false."
        case .notANumber: "Enter a number, such as 0.5."
        case .notAnInteger: "Enter a whole number."
        }
    }
}

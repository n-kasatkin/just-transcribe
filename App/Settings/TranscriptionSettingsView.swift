import JustTranscribeKit
import SwiftUI

/// Provider, then its API key, then its model: ostt accepts a cloud model only once the key is saved.
/// The provider's options follow, for its selected model or else its first.
struct TranscriptionSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Picker("Provider", selection: Binding(get: { model.providerID }, set: { model.selectProvider($0) })) {
                    ForEach(OsttProvider.cloud) { provider in
                        Text(provider.name).tag(provider.id)
                    }
                }
            } footer: {
                if let current = model.currentModel, OsttProvider.withID(current.provider)?.isLocal == true {
                    Text("Now using the offline model \(current.description). Choosing a cloud model below switches to it.")
                }
            }

            Section("API key") {
                LabeledContent("Saved key") {
                    Text(model.maskedKey ?? "None").foregroundStyle(.secondary).monospaced()
                }
                SecureField("Paste a new key", text: $model.keyDraft)
                    .onSubmit { model.saveKey() }
                HStack {
                    Spacer()
                    Button("Remove", role: .destructive) { model.removeKey() }
                        .disabled(model.maskedKey == nil)
                    Button("Save") { model.saveKey() }
                        .disabled(model.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .keyboardShortcut(.defaultAction)
                }
            }

            Section {
                modelPicker
            } header: {
                Text("Model")
            } footer: {
                if model.maskedKey == nil {
                    Text("Save a key to choose a model.")
                } else {
                    catalogFooter
                }
            }

            if let models = model.cloudModels.value, let shown = models.first(where: \.active) ?? models.first {
                ProviderOptionsSection(model: model, id: shown.id, modelName: shown.name)
                    .id(shown.id)
            }

            if model.currentModelMissingKey, let current = model.currentModel {
                Label("\(current.description) is selected, but \(current.provider) has no saved key.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            if let error = model.transcriptionError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
        .task { await model.loadTranscription() }
    }

    @ViewBuilder private var modelPicker: some View {
        switch model.cloudModels {
        case .idle, .loading:
            ProgressView().controlSize(.small)
        case .failed(let message):
            Text(message).foregroundStyle(.red)
        case .loaded(let models):
            Picker("Model", selection: Binding(
                get: { models.first(where: \.active)?.id },
                set: { id in
                    // ostt refuses a model it doesn't list.
                    if let id, models.contains(where: { $0.id == id }) { Task { await model.useCloudModel(id) } }
                }
            )) {
                Text("None").tag(OsttModelID?.none)
                if let catalog = model.providerCatalog {
                    ForEach(ElevenLabsCatalog.merge(ostt: models, remote: catalog.value ?? [])) { item in
                        Text(Self.label(item))
                            .tag(Optional(OsttModelID(provider: model.providerID, model: item.id)))
                            .selectionDisabled(!item.selectable)
                    }
                } else {
                    ForEach(models) { item in
                        Text(item.name).tag(Optional(item.id))
                    }
                }
            }
            .disabled(model.maskedKey == nil)
        }
    }

    @ViewBuilder private var catalogFooter: some View {
        switch model.providerCatalog {
        case .loaded:
            Text("Models ostt can't transcribe with are listed but greyed out. Prices are ElevenLabs credits per character; Scribe bills per audio minute, which the API doesn't report.")
        case .failed(let message):
            Text("Couldn't load ElevenLabs' model list: \(message)")
        case .idle, .loading, nil:
            EmptyView()
        }
    }

    /// "Eleven v3 · text → audio · 1 credit/char"
    private static func label(_ item: CatalogModel) -> String {
        let side = { (modalities: Set<Modality>) in
            modalities.isEmpty ? "?" : modalities.sorted().map(\.rawValue).joined(separator: "/")
        }
        var parts = [item.name, "\(side(item.inputs)) → \(side(item.outputs))"]
        if let credits = item.creditsPerCharacter {
            parts.append("\(credits.formatted()) credit/char")
        }
        return parts.joined(separator: " · ")
    }
}

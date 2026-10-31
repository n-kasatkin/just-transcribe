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
                    if let id { Task { await model.useCloudModel(id) } }
                }
            )) {
                Text("None").tag(OsttModelID?.none)
                ForEach(models) { item in
                    Text(item.name).tag(Optional(item.id))
                }
            }
            .disabled(model.maskedKey == nil)
        }
    }
}

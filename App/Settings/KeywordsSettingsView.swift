import SwiftUI

/// ostt's transcription keywords; replacements and other options live in `ostt.toml`.
struct KeywordsSettingsView: View {
    @Bindable var model: SettingsModel

    var body: some View {
        Form {
            Section {
                HStack {
                    TextField("New keyword", text: $model.keywordDraft)
                        .onSubmit { Task { await model.addKeyword() } }
                    Button("Add") { Task { await model.addKeyword() } }
                        .disabled(model.keywordDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = model.keywordError {
                    Text(error).foregroundStyle(.red)
                }
            } footer: {
                Text("Names and terms the engine should spell exactly as written.")
            }

            Section("Keywords") {
                switch model.keywords {
                case .idle, .loading:
                    ProgressView().controlSize(.small)
                case .failed(let message):
                    HStack {
                        Text(message).foregroundStyle(.red)
                        Spacer()
                        Button("Retry") { Task { await model.loadKeywords() } }
                    }
                case .loaded(let keywords) where keywords.isEmpty:
                    Text("No keywords yet.").foregroundStyle(.secondary)
                case .loaded(let keywords):
                    ForEach(keywords, id: \.self) { keyword in
                        HStack {
                            Text(keyword)
                            Spacer()
                            Button("Remove", systemImage: "minus.circle", role: .destructive) {
                                Task { await model.removeKeyword(keyword) }
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                Button("Open ostt.toml") { Task { await model.openConfigFile() } }
            } footer: {
                Text("Text replacements and advanced engine options are set in ostt's config file.")
            }
        }
        .formStyle(.grouped)
        .task { await model.loadKeywords() }
    }
}

import JustTranscribeKit
import SwiftUI

/// Whisper and Parakeet models from ostt's registry: download with progress, remove, use; options for
/// the one in use.
struct OfflineModelsView: View {
    let model: SettingsModel

    var body: some View {
        Form {
            if let error = model.offlineError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
            if let current = model.currentModel, OsttProvider.withID(current.provider)?.isLocal == true {
                let name = model.localModels[current.provider]?.value?.first { $0.id == current }?.name
                ProviderOptionsSection(model: model, id: current, modelName: name ?? current.model)
                    .id(current)
            }
            ForEach(OsttProvider.local) { provider in
                Section(provider.name) {
                    switch model.localModels[provider.id] ?? .idle {
                    case .idle, .loading:
                        ProgressView().controlSize(.small)
                    case .failed(let message):
                        HStack {
                            Text(message).foregroundStyle(.red)
                            Spacer()
                            Button("Retry") { Task { await model.loadLocalModels() } }
                        }
                    case .loaded(let models):
                        let recommended = model.recommendedModel(provider: provider.id)
                        ForEach(models) { item in
                            OfflineModelRow(model: model, item: item, isRecommended: item.id == recommended)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task { await model.loadOfflineModelsIfNeeded() }
    }
}

private struct OfflineModelRow: View {
    let model: SettingsModel
    let item: OsttModel
    let isRecommended: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.name)
                if isRecommended { Badge("Recommended", color: .accentColor) }
                if item.active { Badge("In use", color: .green) }
                Spacer()
                if let size = item.sizeMB {
                    Text("\(size) MB")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                actions
            }
            if let progress = model.downloads.progress[item.id] {
                ProgressView(value: progress?.fraction) {
                    Text(progressText(progress)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
    }

    @ViewBuilder private var actions: some View {
        if model.downloads.isDownloading(item.id) {
            Button("Cancel") { model.cancelDownload(item.id) }
        } else if item.installed == true {
            Button("Remove", role: .destructive) { Task { await model.removeLocalModel(item.id) } }
            Button("Use") { Task { await model.useLocalModel(item.id) } }
                .disabled(model.currentModel == item.id)
        } else {
            Button("Download") { model.download(item.id) }
        }
    }

    private func progressText(_ progress: DownloadProgress?) -> String {
        guard let progress else { return "Starting…" }
        let speed = String(format: "%.1f MB/s", progress.megabytesPerSecond)
        if let total = progress.total {
            return "\(progress.downloaded) of \(total) · \(speed)"
        }
        return "\(progress.downloaded) · \(speed)"
    }
}

private struct Badge: View {
    let title: String
    let color: Color

    init(_ title: String, color: Color) {
        self.title = title
        self.color = color
    }

    var body: some View {
        Text(title)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }
}

import SwiftUI

/// The Settings window: any leading tabs the caller passes (the General tab), then Transcription,
/// Offline models and Keywords, then any trailing tabs (History and Storage).
struct SettingsView<LeadingTabs: View, TrailingTabs: View>: View {
    let model: SettingsModel
    private let leadingTabs: LeadingTabs
    private let trailingTabs: TrailingTabs

    /// - Parameters:
    ///   - leadingTabs: views with their own `.tabItem`, shown before the built-in tabs.
    ///   - trailingTabs: views with their own `.tabItem`, shown after them.
    init(
        model: SettingsModel, @ViewBuilder leadingTabs: () -> LeadingTabs, @ViewBuilder trailingTabs: () -> TrailingTabs
    ) {
        self.model = model
        self.leadingTabs = leadingTabs()
        self.trailingTabs = trailingTabs()
    }

    var body: some View {
        TabView {
            leadingTabs
            TranscriptionSettingsView(model: model)
                .tabItem { Label("Transcription", systemImage: "waveform") }
            OfflineModelsView(model: model)
                .tabItem { Label("Offline models", systemImage: "arrow.down.circle") }
            KeywordsSettingsView(model: model)
                .tabItem { Label("Keywords", systemImage: "character.book.closed") }
            trailingTabs
        }
        .frame(minWidth: 560, minHeight: 440)
    }
}

extension SettingsView where LeadingTabs == EmptyView, TrailingTabs == EmptyView {
    init(model: SettingsModel) {
        self.init(model: model) { EmptyView() } trailingTabs: { EmptyView() }
    }
}

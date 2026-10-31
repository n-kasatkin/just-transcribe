import SwiftUI

/// The Settings window: any leading tabs the caller passes (the General tab), then Transcription,
/// Offline models and Keywords.
struct SettingsView<LeadingTabs: View>: View {
    let model: SettingsModel
    private let leadingTabs: LeadingTabs

    /// - Parameter leadingTabs: views with their own `.tabItem`, shown before the built-in tabs.
    init(model: SettingsModel, @ViewBuilder leadingTabs: () -> LeadingTabs) {
        self.model = model
        self.leadingTabs = leadingTabs()
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
        }
        .frame(minWidth: 520, minHeight: 440)
    }
}

extension SettingsView where LeadingTabs == EmptyView {
    init(model: SettingsModel) {
        self.init(model: model) { EmptyView() }
    }
}

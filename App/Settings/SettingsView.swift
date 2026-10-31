import JustTranscribeKit
import SwiftUI

/// A section of the Settings sidebar.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, transcription, offlineModels, keywords, history, storage

    /// UserDefaults key of the selected section, so the window reopens where it was left.
    static let storageKey = "settingsSection"

    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .transcription: "Transcription"
        case .offlineModels: "Offline models"
        case .keywords: "Keywords"
        case .history: "History"
        case .storage: "Storage"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .transcription: "waveform"
        case .offlineModels: "arrow.down.circle"
        case .keywords: "character.book.closed"
        case .history: "clock.arrow.circlepath"
        case .storage: "internaldrive"
        }
    }
}

/// The Settings window, laid out like System Settings: a fixed sidebar of sections and the selected pane.
struct SettingsView: View {
    let model: SettingsModel
    let loginItem: LoginItem
    let preferences: AppPreferences
    let history: HistoryStore
    let onRetentionChange: () -> Void
    /// The selected section's title, for the window's title bar.
    let onTitleChange: (String) -> Void
    @AppStorage(SettingsSection.storageKey) private var selection = SettingsSection.general

    var body: some View {
        NavigationSplitView {
            // A click on empty sidebar space would clear the selection; the pane always shows a section.
            let binding = Binding<SettingsSection?>(get: { selection }, set: { if let section = $0 { selection = section } })
            List(SettingsSection.allCases, selection: binding) {
                Label($0.title, systemImage: $0.systemImage)
            }
            // In an AppKit-hosted window the column width alone leaves the sidebar at its narrow default.
            .frame(minWidth: 200)
            .navigationSplitViewColumnWidth(200)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            pane
        }
        .frame(minWidth: 680, minHeight: 440)
        .onChange(of: selection, initial: true) { onTitleChange(selection.title) }
    }

    @ViewBuilder private var pane: some View {
        switch selection {
        case .general: GeneralSettingsView(loginItem: loginItem)
        case .transcription: TranscriptionSettingsView(model: model)
        case .offlineModels: OfflineModelsView(model: model)
        case .keywords: KeywordsSettingsView(model: model)
        case .history: HistorySettingsView(history: history)
        case .storage: StorageSettingsView(preferences: preferences, onRetentionChange: onRetentionChange)
        }
    }
}

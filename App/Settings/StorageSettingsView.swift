import AppKit
import JustTranscribeKit
import SwiftUI

/// How long recordings and history are kept, and the folder new takes are saved to.
struct StorageSettingsView: View {
    let preferences: AppPreferences
    let onRetentionChange: () -> Void
    @AppStorage(AppPreferences.recordingRetentionKey) private var recordingRetention = AppPreferences.defaultRecordingRetention
    @AppStorage(AppPreferences.historyRetentionKey) private var historyRetention = AppPreferences.defaultHistoryRetention
    @AppStorage(AppPreferences.recordingsFolderKey) private var customFolder = ""
    @State private var folderUnavailable = false

    private var folder: URL {
        AppPreferences.recordingsDirectory(customPath: customFolder, paths: preferences.paths)
    }

    var body: some View {
        Form {
            Section {
                retentionPicker("Keep recordings", selection: $recordingRetention)
                retentionPicker("Keep history", selection: $historyRetention)
            } footer: {
                Text("Checked at launch, after each take and every hour.")
            }

            Section {
                LabeledContent("Folder") {
                    Text((folder.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Choose…", action: choose)
                    Button("Show in Finder") { NSWorkspace.shared.open(folder) }
                        .disabled(folderUnavailable)
                    Spacer()
                    Button("Reset to Default") { customFolder = "" }
                        .disabled(customFolder.isEmpty)
                }
                if folderUnavailable {
                    Label("This folder can't be created or written to. Dictation fails until you choose another.",
                          systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Recordings folder")
            } footer: {
                Text("New takes are saved here. Earlier ones stay where they are and are still deleted on schedule. The default is ostt's folder, so `ostt retry` finds the app's takes.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: recordingRetention) { onRetentionChange() }
        .onChange(of: historyRetention) { onRetentionChange() }
        .onChange(of: customFolder) { old, _ in preferences.leaveRecordingsFolder(old) }
        .task(id: customFolder) { await checkFolder() }
    }

    private func retentionPicker(_ title: String, selection: Binding<RetentionPeriod>) -> some View {
        Picker(title, selection: selection) {
            ForEach(RetentionPeriod.allCases) { Text($0.title).tag($0) }
        }
    }

    /// Prepares the folder as a take would, so a problem shows here before the next dictation. Off the
    /// main actor: an unmounted volume can block until the file system times out.
    private func checkFolder() async {
        let store = preferences.recordingStore
        folderUnavailable = await Task.detached { (try? store.prepareDirectory()) == nil }.value
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        customFolder = url.path(percentEncoded: false)
    }
}

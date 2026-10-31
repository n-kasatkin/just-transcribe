import JustTranscribeKit
import SwiftUI

/// Earlier transcripts, newest first, each with a Copy button.
struct HistorySettingsView: View {
    let history: HistoryStore
    @State private var copiedID: HistoryStore.Entry.ID?
    @State private var confirmingClear = false

    var body: some View {
        Form {
            if let error = history.error {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }

            Section {
                if history.entries.isEmpty {
                    Text("No transcripts yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(history.entries) { entry in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.date, format: .dateTime.day().month().year().hour().minute())
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(entry.text)
                                    .lineLimit(4)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Button(copiedID == entry.id ? "Copied" : "Copy") {
                                guard Paster.writeGeneralPasteboard(entry.text) else { return }
                                copiedID = entry.id
                                AccessibilityNotification.Announcement("Copied").post()
                            }
                            .accessibilityLabel("Copy transcript from \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                }
            } footer: {
                Text("The newest \(HistoryStore.capacity) transcripts stay on this Mac. Storage sets how long.")
            }

            Section {
                Button("Clear History…", role: .destructive) { confirmingClear = true }
                    .disabled(history.entries.isEmpty)
            }
        }
        .formStyle(.grouped)
        .task(id: copiedID) {
            guard copiedID != nil else { return }
            // A newer copy cancels this wait and owns the label.
            do { try await Task.sleep(for: .seconds(1.5)) } catch { return }
            copiedID = nil
        }
        .confirmationDialog("Clear the transcript history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        } message: {
            Text("Deletes the transcripts just transcribe keeps. Recordings and ostt's own history are not affected. This can't be undone.")
        }
    }
}

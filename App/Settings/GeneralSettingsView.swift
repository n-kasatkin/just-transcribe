import AVFoundation
import AppKit
import JustTranscribeKit
import KeyboardShortcuts
import SwiftUI

/// Shortcut, start at login and permission status. Checks never prompt; they refresh whenever the
/// app becomes active, so a change made in System Settings shows on return.
struct GeneralSettingsView: View {
    let loginItem: LoginItem
    @State private var microphone = MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio))
    @State private var accessibility = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section {
                KeyboardShortcuts.Recorder("Dictation shortcut", name: .toggleDictation)
            } footer: {
                Text("Press it to start, press it again to paste the text. Escape cancels.")
            }

            Section {
                Toggle("Start at login", isOn: Binding(get: { loginItem.state.isOn }, set: { loginItem.setEnabled($0) }))
                if loginItem.state == .requiresApproval {
                    HStack {
                        Text("Allow just transcribe in Login Items so it starts at login.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { loginItem.openSystemSettings() }
                    }
                }
                if let error = loginItem.errorMessage {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }

            Section("Permissions") {
                PermissionRow(
                    title: "Microphone", detail: "Records your voice while you dictate.",
                    granted: microphone == .granted
                ) {
                    if microphone == .notDetermined {
                        Button("Allow") {
                            Task {
                                _ = await AVCaptureDevice.requestAccess(for: .audio)
                                refresh()
                            }
                        }
                    } else {
                        Button("Open System Settings") { NSWorkspace.shared.open(PrivacyPane.microphone.url) }
                    }
                }
                PermissionRow(
                    title: "Accessibility", detail: "Pastes the text where your cursor is. Without it, the text is only copied.",
                    granted: accessibility
                ) {
                    Button("Open System Settings") { NSWorkspace.shared.open(PrivacyPane.accessibility.url) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        microphone = MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibility = AXIsProcessTrusted()
        loginItem.refresh()
    }
}

private struct PermissionRow<Action: View>: View {
    let title: String
    let detail: String
    let granted: Bool
    @ViewBuilder let action: () -> Action

    var body: some View {
        LabeledContent {
            if granted {
                Label("Granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                HStack {
                    Text("Not granted").foregroundStyle(.secondary)
                    action()
                }
            }
        } label: {
            Text(title)
            Text(detail)
        }
    }
}

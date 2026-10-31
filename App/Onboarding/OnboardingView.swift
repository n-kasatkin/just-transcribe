import AVFoundation
import AppKit
import JustTranscribeKit
import KeyboardShortcuts
import SwiftUI

/// Microphone, Accessibility, hotkey and engine, each with its live status and the action that sets it.
struct OnboardingView: View {
    @Bindable var settings: SettingsModel
    let onDone: () -> Void

    @State private var microphone = MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio))
    @State private var accessibility = AXIsProcessTrusted()
    @State private var hasShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) != nil
    @State private var pastingKey = false

    private var status: OnboardingStatus {
        OnboardingStatus(microphone: microphone, accessibility: accessibility,
                         hasShortcut: hasShortcut, engine: settings.engineReadiness)
    }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    microphoneRow
                    accessibilityRow
                    SetupRow(title: "Hotkey", detail: "Press it to start, press it again to paste the text.",
                             done: hasShortcut, keepsAction: true) {
                        KeyboardShortcuts.Recorder(for: .toggleDictation) { hasShortcut = $0 != nil }
                    }
                    engineRow
                } header: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Press a key. Talk. It's typed.").font(.title2.weight(.semibold))
                        Text("Set up these four things and just transcribe is ready.").foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 8)
                }
                if pastingKey {
                    keySection
                }
                if let error = settings.offlineError {
                    Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(status.summary).foregroundStyle(.secondary)
                Spacer()
                // No default-button shortcut: Return in the key field must save the key, not close the window.
                Button("Done", action: onDone)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 540)
        .task { await loadEngine() }
        // macOS posts no notification for Accessibility or microphone changes made in System Settings.
        .task {
            while !Task.isCancelled {
                refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await settings.refreshEngine() }
        }
    }

    // MARK: Rows

    private var microphoneRow: some View {
        SetupRow(title: "Microphone", detail: "Records your voice while you dictate.", done: microphone == .granted) {
            if microphone == .notDetermined {
                Button("Allow") {
                    Task {
                        _ = await AVCaptureDevice.requestAccess(for: .audio)
                        refreshPermissions()
                    }
                }
            } else {
                Button("Open System Settings") { NSWorkspace.shared.open(PrivacyPane.microphone.url) }
            }
        }
    }

    private var accessibilityRow: some View {
        SetupRow(title: "Accessibility", detail: "Pastes the text where your cursor is.", done: accessibility) {
            Button("Allow") {
                // The key behind kAXTrustedCheckOptionPrompt, a C global Swift 6 treats as unsafe shared state.
                _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
                NSWorkspace.shared.open(PrivacyPane.accessibility.url)
            }
        }
    }

    @ViewBuilder private var engineRow: some View {
        SetupRow(title: "Engine", detail: engineDetail, done: settings.engineReadiness.isReady) { EmptyView() }
        HStack {
            Spacer()
            Button("Paste an API key") { pastingKey.toggle() }
            offlineAction
        }
    }

    private var engineDetail: String {
        switch settings.engineReadiness {
        case .ready(let id): "Using \(id.description)."
        case .missingKey(let id): "\(id.description) is selected, but \(id.provider) has no saved key."
        case .noModel: "Use your own API key, or a model that runs on this Mac."
        }
    }

    // MARK: Offline model

    private var recommended: OsttModel? {
        guard let id = settings.recommendedModel(provider: "whisper") else { return nil }
        return settings.localModels["whisper"]?.value?.first { $0.id == id }
    }

    @ViewBuilder private var offlineAction: some View {
        if let item = recommended {
            if let progress = settings.downloads.progress[item.id] {
                ProgressView(value: progress?.fraction).frame(width: 80)
                Button("Cancel") { settings.cancelDownload(item.id) }
            } else if item.installed == true {
                Button("Use offline model") { Task { await settings.useLocalModel(item.id) } }
                    .disabled(item.active)
            } else {
                Button(item.sizeMB.map { "Download offline model (\($0) MB)" } ?? "Download offline model") {
                    settings.download(item.id, thenUse: true)
                }
            }
        } else if case .failed = settings.localModels["whisper"] {
            Button("Retry model list") { Task { await settings.loadLocalModels() } }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    // MARK: API key

    private var keySection: some View {
        Section("API key") {
            Picker("Provider", selection: Binding(get: { settings.providerID }, set: { settings.selectProvider($0) })) {
                ForEach(OsttProvider.cloud) { provider in
                    Text(provider.name).tag(provider.id)
                }
            }
            SecureField("Paste your key", text: $settings.keyDraft)
                .onSubmit(saveKey)
            HStack {
                if let masked = settings.maskedKey {
                    Text("Saved key \(masked)").foregroundStyle(.secondary).monospaced()
                }
                Spacer()
                Button("Save", action: saveKey)
                    .disabled(settings.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = settings.transcriptionError {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
            }
        }
    }

    private func saveKey() {
        Task { await settings.saveKeyAndUseDefaultModel() }
    }

    // MARK: Status

    /// The key picker starts on the selected cloud provider, else ElevenLabs. The offline list (a network
    /// fetch for the size in the button) loads only while no engine is set.
    private func loadEngine() async {
        await settings.refreshEngine()
        settings.selectProvider(Onboarding.keyProvider(current: settings.currentModel))
        if !settings.engineReadiness.isReady {
            await settings.loadOfflineModelsIfNeeded()
        }
    }

    private func refreshPermissions() {
        microphone = MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio))
        accessibility = AXIsProcessTrusted()
        hasShortcut = KeyboardShortcuts.getShortcut(for: .toggleDictation) != nil
    }
}

private struct SetupRow<Action: View>: View {
    let title: String
    let detail: String
    let done: Bool
    /// Keeps the action once done, for a setting the user may change.
    var keepsAction = false
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? .green : .secondary)
                .imageScale(.large)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !done || keepsAction {
                action()
            }
        }
    }
}

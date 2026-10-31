import AppKit
import JustTranscribeKit
import KeyboardShortcuts
import SwiftUI

/// The menu-bar menu.
struct AppMenu: View {
    let dictation: DictationController
    let settingsWindow: SettingsWindowController
    let onboardingWindow: OnboardingWindowController

    var body: some View {
        let session = dictation.session
        switch session.phase {
        case .idle:
            Button("Start Dictation") { session.toggle() }
                .globalKeyboardShortcut(.toggleDictation)
        case .recording:
            Button("Stop Dictation") { session.toggle() }
                .globalKeyboardShortcut(.toggleDictation)
        case .starting, .transcribing:
            Button("Cancel Dictation") { session.cancel() }
        }
        Button("Retry Last") { session.retryLast() }
            .disabled(!session.phase.canRetry)
        Button("Copy Last") { session.copyLast() }
            .disabled(session.lastTranscript == nil)
        if session.microphoneDenied {
            Button("Allow Microphone Access…") { NSWorkspace.shared.open(PrivacyPane.microphone.url) }
        }
        Divider()
        Button("Setup…") { onboardingWindow.show() }
        Button("Settings…") { settingsWindow.show() }
            .keyboardShortcut(",")
        Button("Check for Updates…") { NSWorkspace.shared.open(Self.releasesURL) }
        Button("About just transcribe") {
            NSApp.activate()
            NSApp.orderFrontStandardAboutPanel(nil)
        }
        Divider()
        Button("Quit just transcribe") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private static let releasesURL = URL(string: "https://github.com/actionhook-dev/just-transcribe/releases/latest")!
}

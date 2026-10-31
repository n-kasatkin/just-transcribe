import AppKit
import JustTranscribeKit
import KeyboardShortcuts
import SwiftUI

/// The menu-bar menu.
struct AppMenu: View {
    let dictation: DictationController
    let settingsWindow: SettingsWindowController

    var body: some View {
        switch dictation.phase {
        case .idle:
            Button("Start Dictation") { dictation.toggle() }
                .globalKeyboardShortcut(.toggleDictation)
        case .recording:
            Button("Stop Dictation") { dictation.toggle() }
                .globalKeyboardShortcut(.toggleDictation)
        case .transcribing:
            Button("Transcribing…") {}
                .disabled(true)
        }
        Button("Retry Last") { dictation.retryLast() }
            .disabled(!dictation.phase.canRetry)
        Button("Copy Last") { dictation.copyLast() }
            .disabled(dictation.lastTranscript == nil)
        if dictation.microphoneDenied {
            Button("Allow Microphone Access…") { NSWorkspace.shared.open(PrivacyPane.microphone.url) }
        }
        Divider()
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

import AppKit
import JustTranscribeKit
import SwiftUI

@main
struct JustTranscribeApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        MenuBarExtra {
            AppMenu(dictation: services.dictation, settingsWindow: services.settingsWindow)
        } label: {
            Label("just transcribe", systemImage: services.dictation.phase.menuBarSymbol)
        }
    }
}

/// The app's long-lived objects. Creating them registers only the user's dictation shortcut.
final class AppServices {
    let dictation: DictationController
    let settingsWindow: SettingsWindowController

    init() {
        let paths = OsttPaths()
        // A missing helper fails each call with OsttError.helperMissing, which the pill and Settings show.
        let process = ProcessOsttRunner(executableURL: Bundle.main.bundleURL.appending(path: "Contents/Helpers/ostt"))
        // One queue for transcription and config writes: ostt rewrites ostt.toml non-atomically.
        let serial = SerialOsttRunner(process)
        let settings = SettingsModel(runner: process, configRunner: serial, paths: paths)
        let settingsWindow = SettingsWindowController(settings: settings, loginItem: LoginItem())
        let dictation = DictationController(runner: serial, paths: paths) { settingsWindow.show() }
        settings.onModelChange = { dictation.modelChanged() }
        self.settingsWindow = settingsWindow
        self.dictation = dictation
    }
}

private extension DictationPhase {
    var menuBarSymbol: String {
        switch self {
        case .idle: "waveform"
        case .recording: "mic.fill"
        case .transcribing: "ellipsis.circle"
        }
    }
}

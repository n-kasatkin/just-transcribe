import AppKit
import JustTranscribeKit
import SwiftUI

@main
struct JustTranscribeApp: App {
    @State private var services = AppServices()

    var body: some Scene {
        MenuBarExtra {
            AppMenu(dictation: services.dictation, settingsWindow: services.settingsWindow, aboutWindow: services.aboutWindow)
        } label: {
            Label("just transcribe", image: services.dictation.session.phase.menuBarImage)
        }
    }
}

/// The app's long-lived objects. Creating them registers only the user's dictation shortcut.
final class AppServices {
    let dictation: DictationController
    let settingsWindow: SettingsWindowController
    let aboutWindow: AboutWindowController

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
        aboutWindow = AboutWindowController(client: OsttSettingsClient(runner: process))
        self.dictation = dictation
    }
}

private extension DictationPhase {
    /// Template images from Assets.xcassets, drawn by scripts/make-icon.swift.
    var menuBarImage: String {
        switch self {
        case .idle: "MenuBarIdle"
        case .starting, .recording: "MenuBarRecording"
        case .transcribing: "MenuBarTranscribing"
        }
    }
}

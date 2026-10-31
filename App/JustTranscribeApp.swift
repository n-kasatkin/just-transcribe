import AppKit
import JustTranscribeKit
import SwiftUI

@main
struct JustTranscribeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    private var services: AppServices { delegate.services }

    var body: some Scene {
        MenuBarExtra {
            AppMenu(dictation: services.dictation, settingsWindow: services.settingsWindow,
                    onboardingWindow: services.onboardingWindow)
        } label: {
            Label("just transcribe", systemImage: services.dictation.session.phase.menuBarSymbol)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    /// After launch, so the onboarding window can come to the front.
    func applicationDidFinishLaunching(_ notification: Notification) {
        services.onboardingWindow.showIfNeeded()
    }
}

/// The app's long-lived objects. Creating them registers only the user's dictation shortcut.
final class AppServices {
    let dictation: DictationController
    let settingsWindow: SettingsWindowController
    let onboardingWindow: OnboardingWindowController

    init() {
        let paths = OsttPaths()
        // A missing helper fails each call with OsttError.helperMissing, which the pill and Settings show.
        let process = ProcessOsttRunner(executableURL: Bundle.main.bundleURL.appending(path: "Contents/Helpers/ostt"))
        // One queue for transcription and config writes: ostt rewrites ostt.toml non-atomically.
        let serial = SerialOsttRunner(process)
        let settings = SettingsModel(runner: process, configRunner: serial, paths: paths)
        let loginItem = LoginItem()
        let settingsWindow = SettingsWindowController(settings: settings, loginItem: loginItem)
        let dictation = DictationController(runner: serial, paths: paths) { settingsWindow.show() }
        settings.onModelChange = { dictation.modelChanged() }
        self.settingsWindow = settingsWindow
        self.dictation = dictation
        onboardingWindow = OnboardingWindowController(settings: settings, loginItem: loginItem)
    }
}

private extension DictationPhase {
    var menuBarSymbol: String {
        switch self {
        case .idle: "waveform"
        case .starting: "mic"
        case .recording: "mic.fill"
        case .transcribing: "ellipsis.circle"
        }
    }
}

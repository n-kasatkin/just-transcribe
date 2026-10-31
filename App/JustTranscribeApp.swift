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
                    onboardingWindow: services.onboardingWindow, aboutWindow: services.aboutWindow)
        } label: {
            Label("just transcribe", image: services.dictation.session.phase.menuBarImage)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    /// After launch, so the onboarding window can come to the front.
    func applicationDidFinishLaunching(_ notification: Notification) {
        services.onboardingWindow.showIfNeeded()
    }

    /// Waits for running model downloads to stop, so no orphaned ostt leaves a partial model behind.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard services.settings.isDownloading else { return .terminateNow }
        let settings = services.settings
        Task {
            // The runner kills ostt within about a second of the cancel; the quit never waits longer than 3 s.
            await withTaskGroup { group in
                group.addTask { await settings.stopDownloads() }
                group.addTask { try? await Task.sleep(for: .seconds(3)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

/// The app's long-lived objects. Creating them registers only the user's dictation shortcut.
final class AppServices {
    let dictation: DictationController
    let settings: SettingsModel
    let settingsWindow: SettingsWindowController
    let onboardingWindow: OnboardingWindowController
    let aboutWindow: AboutWindowController

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
        self.settings = settings
        self.settingsWindow = settingsWindow
        aboutWindow = AboutWindowController(client: OsttSettingsClient(runner: process))
        self.dictation = dictation
        onboardingWindow = OnboardingWindowController(settings: settings, loginItem: loginItem)
    }
}

private extension DictationPhase {
    /// Template images from Assets.xcassets, drawn by scripts/make-icon.swift.
    var menuBarImage: String {
        switch self {
        // The microphone is not live yet while starting.
        case .idle, .starting: "MenuBarIdle"
        case .recording: "MenuBarRecording"
        case .transcribing: "MenuBarTranscribing"
        }
    }
}

import AppKit
import JustTranscribeKit
import SwiftUI

@main
struct JustTranscribeApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @AppStorage(AppPreferences.showMenuBarIconKey) private var showMenuBarIcon = true
    @AppStorage(AppPreferences.hideMenuBarIconConfirmedKey) private var hideConfirmed = false

    private var services: AppServices { delegate.services }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            AppMenu(dictation: services.dictation, settingsWindow: services.settingsWindow,
                    onboardingWindow: services.onboardingWindow, aboutWindow: services.aboutWindow)
        } label: {
            Label("just transcribe", image: services.dictation.session.phase.menuBarImage)
        }
        .onChange(of: showMenuBarIcon) { _, shown in
            // Cmd-dragging the icon out skips the toggle's confirmation; Settings shows the way back instead.
            guard !shown, !hideConfirmed else { return }
            hideConfirmed = true
            services.settingsWindow.show()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let services = AppServices()

    /// After launch, so the onboarding window can come to the front. With the icon hidden, opening the
    /// app shows Settings, as reopening it does; a start at login stays quiet.
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Onboarding.shouldShowAtLaunch(.standard) {
            services.onboardingWindow.show()
        } else if !services.preferences.showMenuBarIcon, !Self.launchedAsLoginItem {
            services.settingsWindow.show()
        }
    }

    private static var launchedAsLoginItem: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    /// Opening the app again (Finder, Spotlight, `open`) is the way back when the menu-bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Onboarding.shouldShowAtLaunch(.standard) {
            services.onboardingWindow.show()
        } else {
            services.settingsWindow.show()
        }
        return false
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

/// The app's long-lived objects. Creating them registers only the user's dictation shortcut and the
/// hourly cleanup.
final class AppServices {
    let dictation: DictationController
    let settings: SettingsModel
    let settingsWindow: SettingsWindowController
    let onboardingWindow: OnboardingWindowController
    let aboutWindow: AboutWindowController
    let preferences: AppPreferences
    private let history: HistoryStore
    private var hourlyCleanup: Task<Void, Never>?

    init() {
        let paths = OsttPaths()
        let preferences = AppPreferences(paths: paths)
        let history = HistoryStore()
        // A missing helper fails each call with OsttError.helperMissing, which the pill and Settings show.
        let process = ProcessOsttRunner(executableURL: Bundle.main.bundleURL.appending(path: "Contents/Helpers/ostt"))
        // One queue for transcription and config writes: ostt rewrites ostt.toml non-atomically.
        let serial = SerialOsttRunner(process)
        let settings = SettingsModel(runner: process, configRunner: serial, paths: paths)
        let loginItem = LoginItem()
        let settingsWindow = SettingsWindowController(
            settings: settings, loginItem: loginItem, preferences: preferences, history: history
        )
        let dictation = DictationController(runner: serial, preferences: preferences, history: history) {
            settingsWindow.show()
        }
        settings.onModelChange = { dictation.modelChanged() }
        self.settings = settings
        self.settingsWindow = settingsWindow
        aboutWindow = AboutWindowController(client: OsttSettingsClient(runner: process))
        self.dictation = dictation
        onboardingWindow = OnboardingWindowController(settings: settings, loginItem: loginItem)
        self.preferences = preferences
        self.history = history
        settingsWindow.onRetentionChange = { [weak self] in self?.cleanUp() }
        cleanUp()
        hourlyCleanup = Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(3600))) != nil {
                self?.cleanUp()
            }
        }
    }

    /// Deletes recordings in every known folder and history entries past their retention; each take
    /// also cleans the current folder.
    func cleanUp() {
        let now = Date.now
        if let cutoff = preferences.historyRetention.cutoff(before: now) {
            history.removeOlder(than: cutoff)
        }
        guard let cutoff = preferences.recordingRetention.cutoff(before: now) else { return }
        let stores = preferences.cleanedRecordingStores
        Task.detached(priority: .utility) {
            for store in stores { store.deleteRecordings(olderThan: cutoff) }
        }
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

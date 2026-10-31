import AppKit
import JustTranscribeKit
import SwiftUI

/// The Settings window, as an AppKit window so the menu and the dictation flow can open it
/// without a SwiftUI environment.
final class SettingsWindowController {
    private let settings: SettingsModel
    private let loginItem: LoginItem
    private let preferences: AppPreferences
    private let history: HistoryStore
    private var window: NSWindow?
    /// A retention choice changed, so the cleanup runs now instead of at the next hour.
    var onRetentionChange: (() -> Void)?

    init(settings: SettingsModel, loginItem: LoginItem, preferences: AppPreferences, history: HistoryStore) {
        self.settings = settings
        self.loginItem = loginItem
        self.preferences = preferences
        self.history = history
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // A menu-bar app is not active, so its window would open behind the frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // From the global hotkey macOS may refuse the activation; the window still comes to the front.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let view = SettingsView(model: settings) {
            GeneralSettingsView(loginItem: loginItem)
                .tabItem { Label("General", systemImage: "gearshape") }
        } trailingTabs: {
            HistorySettingsView(history: history)
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
            StorageSettingsView(preferences: preferences) { [weak self] in self?.onRetentionChange?() }
                .tabItem { Label("Storage", systemImage: "internaldrive") }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "just transcribe Settings"
        window.styleMask.remove(.miniaturizable)
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

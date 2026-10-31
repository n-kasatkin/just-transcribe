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

    /// - Parameter section: the section to select; nil keeps the last one.
    func show(_ section: SettingsSection? = nil) {
        // The sidebar's @AppStorage follows the defaults change.
        if let section { UserDefaults.standard.set(section.rawValue, forKey: SettingsSection.storageKey) }
        let window = window ?? makeWindow()
        self.window = window
        // A menu-bar app is not active, so its window would open behind the frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        // From the global hotkey macOS may refuse the activation; the window still comes to the front.
        window.orderFrontRegardless()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero, styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        let view = SettingsView(
            model: settings, loginItem: loginItem, preferences: preferences, history: history,
            onRetentionChange: { [weak self] in self?.onRetentionChange?() },
            // As in System Settings, the title bar names the section.
            onTitleChange: { [weak window] in window?.title = $0 }
        )
        let hosting = NSHostingController(rootView: view)
        // The split view's toolbar goes to the window, so its sidebar toggle can be removed.
        hosting.sceneBridgingOptions = .toolbars
        window.contentViewController = hosting
        window.toolbarStyle = .unified
        window.setContentSize(NSSize(width: 740, height: 540))
        window.isReleasedWhenClosed = false
        window.center()
        return window
    }
}

import AppKit
import JustTranscribeKit
import SwiftUI

/// The setup window: shown at first launch until the user presses Done, and from the menu's "Setup…".
final class OnboardingWindowController {
    private let settings: SettingsModel
    private let loginItem: LoginItem
    private let defaults: UserDefaults
    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?

    init(settings: SettingsModel, loginItem: LoginItem, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.loginItem = loginItem
        self.defaults = defaults
    }

    func showIfNeeded() {
        if Onboarding.shouldShowAtLaunch(defaults) { show() }
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // A menu-bar app is not active, so its window would open behind the frontmost app.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func finish() {
        loginItem.refresh()
        if !loginItem.state.isOn { loginItem.setEnabled(true) }
        defaults.set(true, forKey: Onboarding.completedKey)
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(settings: settings) { [weak self] in self?.finish() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Set up just transcribe"
        window.styleMask.remove([.miniaturizable, .resizable])
        window.isReleasedWhenClosed = false
        window.center()
        // Dropping the window on close ends the view's 1 s permission polling.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.windowWillClose() }
        }
        return window
    }

    private func windowWillClose() {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        window = nil
    }
}

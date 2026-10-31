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
    /// A start-at-login failure was shown beside Done; the next Done closes the window anyway.
    private var loginFailureShown = false

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
        defaults.set(true, forKey: Onboarding.completedKey)
        loginItem.refresh()
        if !loginItem.state.isOn {
            loginItem.setEnabled(true)
            if loginItem.errorMessage != nil, !loginFailureShown {
                loginFailureShown = true
                return
            }
        }
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let view = OnboardingView(settings: settings, loginItem: loginItem) { [weak self] in self?.finish() }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Set up just transcribe"
        window.styleMask.remove([.miniaturizable, .resizable])
        window.isReleasedWhenClosed = false
        window.center()
        // Tearing down the hosting controller on close cancels the view's tasks, including the 1 s polling.
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
        loginFailureShown = false
        window?.contentViewController = nil
        window = nil
    }
}

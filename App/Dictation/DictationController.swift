import AppKit
import JustTranscribeKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// No default: the user picks the shortcut in Settings.
    nonisolated static let toggleDictation = Self("toggleDictation")
}

/// Connects `DictationSession` to the hotkeys, the recorder's level and the pill.
final class DictationController {
    let session: DictationSession

    private let models: ActiveModelCache
    private let pill = PillController()
    private var escapeListener: Task<Void, Never>?
    private var menuObserver: (any NSObjectProtocol)?

    /// - Parameter runner: the serial queue shared with Settings' config writes.
    init(
        runner: any OsttRunning, preferences: AppPreferences, history: HistoryStore, openSettings: @escaping () -> Void
    ) {
        let recorder = Recorder()
        let models = ActiveModelCache(runner: runner, configFile: preferences.paths.configFile)
        self.models = models
        session = DictationSession(.live(
            recorder: recorder, models: models, transcriber: Transcriber(runner: runner),
            preferences: preferences, history: history, paster: Paster()
        ))
        recorder.onLevel = { [weak self] in self?.pill.setLevel($0) }
        recorder.onInterrupted = { [weak self] in self?.session.interrupted() }
        session.onPhaseChange = { [weak self] in self?.phaseChanged($0) }
        session.onFeedback = { [weak self] in self?.show($0) }
        session.onNoModel = openSettings
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in self?.session.toggle() }
        // Picks up a microphone grant made in System Settings before the menu shows.
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.session.refreshMicrophoneAccess() }
        }
    }

    /// Settings selected or removed a model.
    func modelChanged() {
        Task { await models.invalidate() }
    }

    private func show(_ feedback: DictationFeedback) {
        switch feedback {
        case .hidden: pill.hide()
        case .notice(let text): pill.show(.notice(text))
        case .error(let text): pill.show(.error(text))
        }
    }

    private func phaseChanged(_ phase: DictationPhase) {
        switch phase {
        case .idle, .starting: break
        case .recording: pill.show(.recording)
        case .transcribing: pill.show(.transcribing)
        }
        // Escape is a global hotkey only while busy, so it reaches other apps the rest of the time.
        if phase.isBusy, escapeListener == nil {
            escapeListener = Task { [weak self] in
                for await _ in KeyboardShortcuts.events(.keyDown, for: KeyboardShortcuts.Shortcut(.escape)) {
                    guard let self else { return }
                    session.cancel()
                }
            }
        } else if !phase.isBusy {
            escapeListener?.cancel()
            escapeListener = nil
        }
    }
}

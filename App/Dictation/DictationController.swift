import AVFoundation
import JustTranscribeKit
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    /// No default: the user picks the shortcut in Settings.
    nonisolated static let toggleDictation = Self("toggleDictation")
}

/// Hotkey → record → save → `ostt transcribe` → paste. The rules for each step live in
/// `DictationPhase` and `DictationFeedback`; this class runs them.
@Observable
final class DictationController {
    private(set) var phase: DictationPhase = .idle
    /// The last transcript of this session, for Copy Last.
    private(set) var lastTranscript: String?
    /// The last start failed for lack of microphone access; the menu then links to the pane.
    private(set) var microphoneDenied = false

    @ObservationIgnored private let models: ActiveModelCache
    @ObservationIgnored private let transcriber: Transcriber
    @ObservationIgnored private let store: RecordingStore
    @ObservationIgnored private let openSettings: () -> Void
    @ObservationIgnored private let recorder = Recorder()
    @ObservationIgnored private let pill = PillController()
    @ObservationIgnored private let paster = Paster()
    @ObservationIgnored private var container = AudioContainer.m4a
    /// A start waiting for the microphone prompt or `ostt model current`.
    @ObservationIgnored private var starting = false
    /// Saving and transcribing; Escape cancels it, which kills ostt.
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var escapeListener: Task<Void, Never>?

    /// - Parameter runner: the serial queue shared with Settings' config writes.
    init(runner: any OsttRunning, paths: OsttPaths, openSettings: @escaping () -> Void) {
        models = ActiveModelCache(runner: runner, configFile: paths.configFile)
        transcriber = Transcriber(runner: runner)
        store = RecordingStore(paths: paths)
        self.openSettings = openSettings
        recorder.onLevel = { [weak self] in self?.pill.setLevel($0) }
        recorder.onInterrupted = { [weak self] in
            guard let self else { return }
            perform(phase.onInterrupted)
        }
        KeyboardShortcuts.onKeyDown(for: .toggleDictation) { [weak self] in
            guard let self else { return }
            perform(phase.onToggle)
        }
    }

    func toggle() {
        perform(phase.onToggle)
    }

    /// Settings selected or removed a model.
    func modelChanged() {
        Task { await models.invalidate() }
    }

    func retryLast() {
        guard phase.canRetry, !starting else { return }
        guard let file = store.latestRecording() else {
            show(.failure(DictationError.noRecording))
            return
        }
        setPhase(.transcribing)
        work = Task {
            do {
                guard let model = try await models.current() else { throw DictationError.noModel }
                let (ready, duration) = try await Task.detached { try RetryTake.prepare(file, for: model) }.value
                try await transcribeAndPaste(ready, duration: duration)
            } catch {
                fail(error)
            }
        }
    }

    func copyLast() {
        guard let lastTranscript else { return }
        show(Paster.writeGeneralPasteboard(lastTranscript) ? .copied : .error("Copy failed"))
    }

    private func perform(_ command: DictationCommand) {
        switch command {
        case .none:
            break
        case .start:
            start()
        case .stopAndTranscribe:
            stop()
        case .discardRecording:
            recorder.cancel()
            finish(.hidden)
        case .cancelTranscription:
            work?.cancel()
        }
    }

    private func start() {
        guard !starting else { return }
        starting = true
        Task {
            defer { starting = false }
            do {
                try await requireMicrophone()
                guard let model = try await models.current() else { throw DictationError.noModel }
                container = AudioContainer(model.audioFormat)
                try recorder.start()
                setPhase(.recording)
            } catch {
                fail(error)
            }
        }
    }

    /// Asks for the microphone only here, after the user pressed the hotkey.
    private func requireMicrophone() async throws {
        switch MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio)) {
        case .granted:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw DictationError.microphoneDenied }
        case .denied:
            throw DictationError.microphoneDenied
        }
        microphoneDenied = false
    }

    private func stop() {
        let samples = recorder.stop()
        let container = container
        let store = store
        setPhase(.transcribing)
        work = Task {
            do {
                let take = try await Task.detached { try Take.save(samples, as: container, in: store) }.value
                guard case .saved(let file, let seconds) = take else {
                    finish(.nothingHeard)
                    return
                }
                try await transcribeAndPaste(file, duration: .seconds(seconds))
            } catch {
                fail(error)
            }
        }
    }

    private func transcribeAndPaste(_ file: URL, duration: Duration) async throws {
        let text = try await transcriber.transcribe(file: file, audioDuration: duration)
        try Task.checkCancellation()
        lastTranscript = text
        finish(.paste(await paster.paste(text)))
    }

    /// Any saved recording stays in ostt's folder for Retry Last.
    private func fail(_ error: any Error) {
        switch error {
        case DictationError.microphoneDenied, RecorderError.microphoneNotAuthorized:
            microphoneDenied = true
        case DictationError.noModel:
            openSettings()
        default:
            break
        }
        finish(.failure(error))
    }

    private func finish(_ feedback: DictationFeedback) {
        work = nil
        setPhase(.idle)
        show(feedback)
    }

    private func show(_ feedback: DictationFeedback) {
        switch feedback {
        case .hidden: pill.hide()
        case .notice(let text): pill.show(.notice(text))
        case .error(let text): pill.show(.error(text))
        }
    }

    private func setPhase(_ newPhase: DictationPhase) {
        phase = newPhase
        switch newPhase {
        case .idle: break
        case .recording: pill.show(.recording)
        case .transcribing: pill.show(.transcribing)
        }
        // Escape is a global hotkey only while busy, so it reaches other apps the rest of the time.
        if newPhase.isBusy, escapeListener == nil {
            escapeListener = Task { [weak self] in
                for await _ in KeyboardShortcuts.events(.keyDown, for: KeyboardShortcuts.Shortcut(.escape)) {
                    guard let self else { return }
                    perform(phase.onEscape)
                }
            }
        } else if !newPhase.isBusy {
            escapeListener?.cancel()
            escapeListener = nil
        }
    }
}

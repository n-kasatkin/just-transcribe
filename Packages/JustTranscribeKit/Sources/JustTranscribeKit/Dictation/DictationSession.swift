import AVFoundation
import Observation

/// Runs dictations one at a time: start, stop, cancel, retry and copy. `DictationPhase` holds the
/// rules; this type sequences the steps and reports each outcome through `onFeedback`.
@MainActor
@Observable
public final class DictationSession {
    /// The outside world, injected so tests can drive every step.
    public struct Dependencies {
        public var microphoneAccess: @MainActor () -> MicrophoneAccess
        /// Shows the system prompt; true when the user allowed access.
        public var requestMicrophone: @MainActor () async -> Bool
        public var currentModel: @Sendable () async throws -> ActiveModel?
        public var startRecording: @MainActor () throws -> Void
        public var stopRecording: @MainActor () -> [Float]
        public var cancelRecording: @MainActor () -> Void
        /// Runs off the main actor.
        public var save: @Sendable ([Float], AudioContainer) throws -> TakeResult
        public var latestRecording: @Sendable () -> URL?
        /// Runs off the main actor.
        public var prepareRetry: @Sendable (URL, ActiveModel) throws -> (file: URL, duration: Duration)
        public var transcribe: @Sendable (URL, Duration) async throws -> String
        public var paste: @MainActor (String) async -> Paster.Outcome
        public var copy: @MainActor (String) -> Bool

        public init(
            microphoneAccess: @escaping @MainActor () -> MicrophoneAccess,
            requestMicrophone: @escaping @MainActor () async -> Bool,
            currentModel: @escaping @Sendable () async throws -> ActiveModel?,
            startRecording: @escaping @MainActor () throws -> Void,
            stopRecording: @escaping @MainActor () -> [Float],
            cancelRecording: @escaping @MainActor () -> Void,
            save: @escaping @Sendable ([Float], AudioContainer) throws -> TakeResult,
            latestRecording: @escaping @Sendable () -> URL?,
            prepareRetry: @escaping @Sendable (URL, ActiveModel) throws -> (file: URL, duration: Duration),
            transcribe: @escaping @Sendable (URL, Duration) async throws -> String,
            paste: @escaping @MainActor (String) async -> Paster.Outcome,
            copy: @escaping @MainActor (String) -> Bool
        ) {
            self.microphoneAccess = microphoneAccess
            self.requestMicrophone = requestMicrophone
            self.currentModel = currentModel
            self.startRecording = startRecording
            self.stopRecording = stopRecording
            self.cancelRecording = cancelRecording
            self.save = save
            self.latestRecording = latestRecording
            self.prepareRetry = prepareRetry
            self.transcribe = transcribe
            self.paste = paste
            self.copy = copy
        }

        /// The app's wiring: the real microphone, ostt through `models` and `transcriber`, ostt's
        /// recordings folder and the system pasteboard.
        @MainActor
        public static func live(
            recorder: Recorder, models: ActiveModelCache, transcriber: Transcriber, store: RecordingStore, paster: Paster
        ) -> Dependencies {
            Dependencies(
                microphoneAccess: { MicrophoneAccess(AVCaptureDevice.authorizationStatus(for: .audio)) },
                requestMicrophone: { await AVCaptureDevice.requestAccess(for: .audio) },
                currentModel: { try await models.current() },
                startRecording: { try recorder.start() },
                stopRecording: { recorder.stop() },
                cancelRecording: { recorder.cancel() },
                save: { try Take.save($0, as: $1, in: store) },
                latestRecording: { store.latestRecording() },
                prepareRetry: { try RetryTake.prepare($0, for: $1) },
                transcribe: { try await transcriber.transcribe(file: $0, audioDuration: $1) },
                paste: { await paster.paste($0) },
                copy: { Paster.writeGeneralPasteboard($0) }
            )
        }
    }

    public private(set) var phase: DictationPhase = .idle
    /// The last transcript of this session, for Copy Last.
    public private(set) var lastTranscript: String?
    /// Microphone access is denied; the menu then links to the pane.
    public private(set) var microphoneDenied = false

    /// Every phase change, for the pill and the Escape hotkey.
    @ObservationIgnored public var onPhaseChange: ((DictationPhase) -> Void)?
    /// What the pill shows when a step ends.
    @ObservationIgnored public var onFeedback: ((DictationFeedback) -> Void)?
    /// A start or retry found no model selected.
    @ObservationIgnored public var onNoModel: (() -> Void)?

    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private var container = AudioContainer.m4a
    /// Starting, saving or transcribing; cancel stops it.
    @ObservationIgnored private(set) var work: Task<Void, Never>?
    /// Bumped whenever a dictation ends. Work that outlives its cancel (a pending microphone prompt,
    /// a save in a detached task) compares it and drops its result.
    @ObservationIgnored private var generation = 0

    public init(_ dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    public func toggle() {
        perform(phase.onToggle)
    }

    /// Escape, or Cancel in the menu.
    public func cancel() {
        perform(phase.onEscape)
    }

    /// The recorder lost its input mid-recording.
    public func interrupted() {
        perform(phase.onInterrupted)
    }

    /// Reads the live permission, so a grant made in System Settings shows without a dictation.
    public func refreshMicrophoneAccess() {
        microphoneDenied = dependencies.microphoneAccess() == .denied
    }

    public func retryLast() {
        guard phase.canRetry else { return }
        guard let file = dependencies.latestRecording() else {
            onFeedback?(.failure(DictationError.noRecording))
            return
        }
        setPhase(.transcribing)
        let id = generation
        let prepare = dependencies.prepareRetry
        work = Task {
            do {
                guard let model = try await dependencies.currentModel() else { throw DictationError.noModel }
                let (ready, duration) = try await Task.detached { try prepare(file, model) }.value
                guard id == generation else { return }
                try await transcribeAndPaste(ready, duration: duration, id: id)
            } catch {
                if id == generation { fail(error) }
            }
        }
    }

    public func copyLast() {
        guard let lastTranscript else { return }
        onFeedback?(dependencies.copy(lastTranscript) ? .copied : .error("Copy failed"))
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
            dependencies.cancelRecording()
            finish(.hidden)
        case .cancel:
            work?.cancel()
            finish(.hidden)
        }
    }

    private func start() {
        setPhase(.starting)
        let id = generation
        work = Task {
            do {
                try await requireMicrophone()
                guard let model = try await dependencies.currentModel() else { throw DictationError.noModel }
                guard id == generation else { return }
                container = AudioContainer(model.audioFormat)
                try dependencies.startRecording()
                work = nil
                setPhase(.recording)
            } catch {
                if id == generation { fail(error) }
            }
        }
    }

    /// Asks for the microphone only here, after the user pressed the hotkey.
    private func requireMicrophone() async throws {
        switch dependencies.microphoneAccess() {
        case .granted:
            break
        case .notDetermined:
            guard await dependencies.requestMicrophone() else { throw DictationError.microphoneDenied }
        case .denied:
            throw DictationError.microphoneDenied
        }
        microphoneDenied = false
    }

    private func stop() {
        let samples = dependencies.stopRecording()
        let container = container
        let save = dependencies.save
        setPhase(.transcribing)
        let id = generation
        work = Task {
            do {
                let take = try await Task.detached { try save(samples, container) }.value
                guard id == generation else { return }
                guard case .saved(let file, let seconds) = take else {
                    finish(.nothingHeard)
                    return
                }
                try await transcribeAndPaste(file, duration: .seconds(seconds), id: id)
            } catch {
                if id == generation { fail(error) }
            }
        }
    }

    private func transcribeAndPaste(_ file: URL, duration: Duration, id: Int) async throws {
        let text = try await dependencies.transcribe(file, duration)
        guard id == generation else { return }
        lastTranscript = text
        let outcome = await dependencies.paste(text)
        guard id == generation else { return }
        finish(.paste(outcome))
    }

    /// Any saved recording stays in ostt's folder for Retry Last.
    private func fail(_ error: any Error) {
        switch error {
        case DictationError.microphoneDenied, RecorderError.microphoneNotAuthorized:
            microphoneDenied = true
        case DictationError.noModel:
            onNoModel?()
        default:
            break
        }
        finish(.failure(error))
    }

    private func finish(_ feedback: DictationFeedback) {
        generation += 1
        work = nil
        setPhase(.idle)
        onFeedback?(feedback)
    }

    private func setPhase(_ newPhase: DictationPhase) {
        phase = newPhase
        onPhaseChange?(newPhase)
    }
}

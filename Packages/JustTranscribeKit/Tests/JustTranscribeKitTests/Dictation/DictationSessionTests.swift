import Foundation
import Testing
@testable import JustTranscribeKit

@MainActor
struct DictationSessionTests {
    /// Fakes for every dependency, recording what the session did.
    @MainActor
    final class Harness {
        var access = MicrophoneAccess.granted
        var prompt: CheckedContinuation<Bool, Never>?
        var recordingsStarted = 0
        var recordingsCancelled = 0
        var pasted: [String] = []
        var feedback: [DictationFeedback] = []
        var phases: [DictationPhase] = []
        var noModelCalls = 0
        let containers = Collector<AudioContainer>()
        let transcribed = Collector<URL>()
        var session: DictationSession!

        init(
            model: ActiveModel? = ActiveModel(providerID: "whisper", modelID: "base"),
            latest: URL? = nil,
            save: @escaping @Sendable ([Float], AudioContainer) throws -> TakeResult = { _, _ in
                .saved(URL(filePath: "/take.wav"), duration: 1)
            },
            transcribe: @escaping @Sendable (URL, Duration) async throws -> String = { _, _ in "привет" },
            paste: (@MainActor (String) async -> Paster.Outcome)? = nil,
            maxRecordingDuration: Duration = .seconds(30 * 60)
        ) {
            let containers = containers
            let transcribed = transcribed
            session = DictationSession(DictationSession.Dependencies(
                microphoneAccess: { self.access },
                requestMicrophone: { await withCheckedContinuation { self.prompt = $0 } },
                currentModel: { model },
                startRecording: { self.recordingsStarted += 1 },
                stopRecording: { [0.5] },
                cancelRecording: { self.recordingsCancelled += 1 },
                save: { samples, container in
                    containers.append(container)
                    return try save(samples, container)
                },
                latestRecording: { latest },
                prepareRetry: { file, _ in (file, .seconds(1)) },
                transcribe: { file, duration in
                    transcribed.append(file)
                    return try await transcribe(file, duration)
                },
                paste: { text in
                    self.pasted.append(text)
                    return await paste?(text) ?? .pasted
                },
                copy: { _ in true }
            ), maxRecordingDuration: maxRecordingDuration)
            session.onPhaseChange = { self.phases.append($0) }
            session.onFeedback = { self.feedback.append($0) }
            session.onNoModel = { self.noModelCalls += 1 }
        }

        /// Starts and waits until capture runs.
        func record() async {
            session.toggle()
            await session.work?.value
        }

        func waitForPrompt() async {
            for _ in 0..<10_000 where prompt == nil {
                await Task.yield()
            }
            #expect(prompt != nil)
        }
    }

    @Test func startStopTranscribesAndPastes() async {
        let harness = Harness()
        await harness.record()
        #expect(harness.session.phase == .recording)
        harness.session.toggle()
        await harness.session.work?.value
        #expect(harness.phases == [.starting, .recording, .transcribing, .idle])
        #expect(harness.containers.values == [.wav])
        #expect(harness.pasted == ["привет"])
        #expect(harness.session.lastTranscript == "привет")
        #expect(harness.feedback == [.hidden])
    }

    @Test func hotkeyDuringTheMicrophonePromptCancelsTheStart() async {
        let harness = Harness()
        harness.access = .notDetermined
        harness.session.toggle()
        await harness.waitForPrompt()
        let pending = harness.session.work
        harness.session.toggle()
        #expect(harness.session.phase == .idle)
        #expect(harness.feedback == [.hidden])

        harness.prompt?.resume(returning: true)
        await pending?.value
        #expect(harness.recordingsStarted == 0)
        #expect(harness.session.phase == .idle)
        #expect(harness.feedback == [.hidden])
    }

    @Test func aCancelledStartDoesNotDisturbTheNextOne() async {
        let harness = Harness()
        harness.access = .notDetermined
        harness.session.toggle()
        await harness.waitForPrompt()
        let pending = harness.session.work
        harness.session.cancel()

        harness.access = .granted
        await harness.record()
        harness.prompt?.resume(returning: false)
        await pending?.value
        #expect(harness.session.phase == .recording)
        #expect(harness.recordingsStarted == 1)
        #expect(harness.feedback == [.hidden])
        #expect(!harness.session.microphoneDenied)
    }

    @Test func escapeWhileSavingShowsNothingHeardNever() async {
        let saving = DispatchSemaphore(value: 0)
        let harness = Harness(save: { _, _ in
            saving.wait()
            return .nothingHeard
        })
        await harness.record()
        harness.session.toggle()
        let pending = harness.session.work
        harness.session.cancel()
        #expect(harness.session.phase == .idle)
        saving.signal()
        await pending?.value
        #expect(harness.feedback == [.hidden])
    }

    @Test func escapeWhileSavingSkipsTranscription() async {
        let saving = DispatchSemaphore(value: 0)
        let harness = Harness(save: { _, _ in
            saving.wait()
            return .saved(URL(filePath: "/take.wav"), duration: 1)
        })
        await harness.record()
        harness.session.toggle()
        let pending = harness.session.work
        harness.session.cancel()
        saving.signal()
        await pending?.value
        #expect(harness.transcribed.values.isEmpty)
        #expect(harness.feedback == [.hidden])
    }

    @Test func escapeWhileTranscribingPastesNothing() async {
        let harness = Harness(transcribe: { _, _ in
            try await Task.sleep(for: .seconds(30))
            return "late"
        })
        await harness.record()
        harness.session.toggle()
        let pending = harness.session.work
        harness.session.cancel()
        #expect(harness.session.phase == .idle)
        await pending?.value
        #expect(harness.pasted.isEmpty)
        #expect(harness.session.lastTranscript == nil)
        #expect(harness.feedback == [.hidden])
    }

    @Test func escapeDuringThePasteDelayTypesNothing() async {
        let keystrokes = Collector<Void>()
        let paster = Paster(
            writePasteboard: { _ in true },
            isAccessibilityTrusted: { true },
            isSecureInputEnabled: { false },
            sendPasteKeystroke: { keystrokes.append(()) },
            keystrokeDelay: .seconds(30)
        )
        let harness = Harness(paste: { await paster.paste($0) })
        await harness.record()
        harness.session.toggle()
        let pending = harness.session.work
        for _ in 0..<10_000 where harness.pasted.isEmpty {
            await Task.yield()
        }
        #expect(harness.pasted == ["привет"])
        harness.session.cancel()
        await pending?.value
        #expect(keystrokes.values.isEmpty)
        #expect(harness.session.phase == .idle)
        #expect(harness.feedback == [.hidden])
    }

    @Test func escapeWhileRecordingDiscardsTheTake() async {
        let harness = Harness()
        await harness.record()
        harness.session.cancel()
        #expect(harness.recordingsCancelled == 1)
        #expect(harness.containers.values.isEmpty)
        #expect(harness.session.phase == .idle)
        #expect(harness.feedback == [.hidden])
    }

    @Test func lostInputTranscribesTheTakeSoFar() async {
        let harness = Harness()
        await harness.record()
        harness.session.interrupted()
        await harness.session.work?.value
        #expect(harness.pasted == ["привет"])
    }

    @Test func aForgottenRecordingStopsAndTranscribesAtTheLimit() async {
        let harness = Harness(maxRecordingDuration: .milliseconds(10))
        await harness.record()
        await harness.session.recordingLimit?.value
        await harness.session.work?.value
        #expect(harness.phases == [.starting, .recording, .transcribing, .idle])
        #expect(harness.pasted == ["привет"])
    }

    @Test func stoppingBeforeTheLimitCancelsIt() async {
        let harness = Harness()
        await harness.record()
        let limit = harness.session.recordingLimit
        #expect(limit != nil)
        harness.session.toggle()
        #expect(harness.session.recordingLimit == nil)
        #expect(limit?.isCancelled == true)
        await harness.session.work?.value
        #expect(harness.pasted == ["привет"])
    }

    @Test func noModelOpensSettings() async {
        let harness = Harness(model: nil)
        await harness.record()
        #expect(harness.noModelCalls == 1)
        #expect(harness.recordingsStarted == 0)
        #expect(harness.session.phase == .idle)
        #expect(harness.feedback == [.error("No engine")])
    }

    @Test func deniedMicrophoneShowsUntilGranted() async {
        let harness = Harness()
        harness.access = .denied
        await harness.record()
        #expect(harness.session.microphoneDenied)
        #expect(harness.feedback == [.error("Microphone access needed")])
        harness.access = .granted
        harness.session.refreshMicrophoneAccess()
        #expect(!harness.session.microphoneDenied)
    }

    @Test func retryTranscribesTheLatestRecording() async {
        let file = URL(filePath: "/ostt-recording-1.m4a")
        let harness = Harness(latest: file)
        harness.session.retryLast()
        #expect(harness.session.phase == .transcribing)
        await harness.session.work?.value
        #expect(harness.transcribed.values == [file])
        #expect(harness.pasted == ["привет"])
        #expect(harness.session.phase == .idle)
    }

    @Test func retryWithoutARecordingSaysSo() {
        let harness = Harness()
        harness.session.retryLast()
        #expect(harness.session.phase == .idle)
        #expect(harness.feedback == [.notice("No recording")])
    }

    @Test func failedTranscriptionReturnsToIdle() async {
        let harness = Harness(transcribe: { _, _ in throw OsttError.timedOut })
        await harness.record()
        harness.session.toggle()
        await harness.session.work?.value
        #expect(harness.session.phase == .idle)
        #expect(harness.feedback == [.error("Timed out")])
        #expect(harness.session.phase.onToggle == .start)
    }
}

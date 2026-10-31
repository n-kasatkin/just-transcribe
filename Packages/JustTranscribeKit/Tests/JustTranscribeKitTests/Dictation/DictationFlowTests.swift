import Foundation
import Testing
@testable import JustTranscribeKit

struct DictationFlowTests {
    @Test func hotkeyStartsThenStopsAndIgnoresPressesWhileTranscribing() {
        #expect(DictationPhase.idle.onToggle == .start)
        #expect(DictationPhase.recording.onToggle == .stopAndTranscribe)
        #expect(DictationPhase.transcribing.onToggle == DictationCommand.none)
    }

    @Test func escapeDiscardsOrCancelsAndIsInertWhenIdle() {
        #expect(DictationPhase.idle.onEscape == DictationCommand.none)
        #expect(DictationPhase.recording.onEscape == .discardRecording)
        #expect(DictationPhase.transcribing.onEscape == .cancelTranscription)
    }

    @Test func interruptionKeepsTheTakeOnlyWhileRecording() {
        #expect(DictationPhase.recording.onInterrupted == .stopAndTranscribe)
        #expect(DictationPhase.idle.onInterrupted == DictationCommand.none)
        #expect(DictationPhase.transcribing.onInterrupted == DictationCommand.none)
    }

    @Test func escapeIsRegisteredOnlyWhileBusyAndRetryOnlyWhenIdle() {
        #expect(!DictationPhase.idle.isBusy)
        #expect(DictationPhase.recording.isBusy)
        #expect(DictationPhase.transcribing.isBusy)
        #expect(DictationPhase.idle.canRetry)
        #expect(!DictationPhase.recording.canRetry)
        #expect(!DictationPhase.transcribing.canRetry)
    }

    @Test func pasteOutcomes() {
        #expect(DictationFeedback.paste(.pasted) == .hidden)
        #expect(DictationFeedback.paste(.copiedOnly) == .notice("Copied"))
    }

    @Test(arguments: [
        (OsttError.timedOut as any Error, DictationFeedback.error("Timed out")),
        (OsttError.helperMissing, .error("ostt missing")),
        (OsttError.cancelled, .hidden),
        (CancellationError(), .hidden),
        (OsttError.failed(OsttResult(exitCode: 1, stdout: "", stderr: "")), .error("ostt failed")),
        (OsttError.failed(OsttResult(exitCode: 1, stdout: "", stderr: "Error: 401 Unauthorized: invalid api key\n")),
         .error("401 Unauthorized: invalid")),
        (Transcriber.Failure.emptyTranscript, .notice("Nothing heard")),
        (DictationError.microphoneDenied, .error("Microphone access needed")),
        (RecorderError.microphoneNotAuthorized, .error("Microphone access needed")),
        (DictationError.noModel, .error("No engine")),
        (DictationError.noRecording, .notice("No recording")),
        (RecorderError.noInputDevice, .error("No microphone")),
        (RecorderError.engineFailed("x"), .error("Microphone failed")),
        (ActiveModel.ParseError.unrecognized("x"), .error("Unknown engine")),
        (CocoaError(.fileWriteNoPermission), .error("Something went wrong")),
    ])
    func failureLabels(error: any Error, feedback: DictationFeedback) {
        #expect(DictationFeedback.failure(error) == feedback)
    }

    @Test func failureLabelsFitThreeWords() {
        let errors: [any Error] = [
            OsttError.timedOut, OsttError.helperMissing, DictationError.microphoneDenied, DictationError.noModel,
            RecorderError.noInputDevice, RecorderError.engineFailed("x"), CocoaError(.fileWriteNoPermission),
            OsttError.failed(OsttResult(exitCode: 1, stdout: "", stderr: "a b c d e f")),
        ]
        for error in errors {
            guard case .error(let label) = DictationFeedback.failure(error) else {
                Issue.record("\(error) is not an error label")
                continue
            }
            #expect(label.split(separator: " ").count <= 3, "\(label)")
        }
    }

    @Test(arguments: [
        ("Error: Transcription failed: network down", "Transcription failed: network"),
        ("    1: error sending request for url", "Error sending request"),
        ("\u{1B}[31mError:\u{1B}[0m Model not found.", "Model not found"),
        ("Error: Invalid params for", "Invalid params for"),
        ("timeout:", "Timeout"),
        ("Error:", "ostt failed"),
        ("   ", "ostt failed"),
        ("Привет мир: снова и снова", "Привет мир: снова"),
    ])
    func shortLabel(line: String, label: String) {
        #expect(DictationFeedback.shortLabel(line) == label)
    }

    @Test func containerFollowsTheEngineFormat() {
        #expect(AudioContainer(EngineAudioFormat.m4a) == .m4a)
        #expect(AudioContainer(EngineAudioFormat.wav) == .wav)
        #expect(AudioContainer(ActiveModel(providerID: "whisper", modelID: "base").audioFormat) == .wav)
        #expect(AudioContainer(ActiveModel(providerID: "elevenlabs", modelID: "scribe_v2").audioFormat) == .m4a)
    }
}

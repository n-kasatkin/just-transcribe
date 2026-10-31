import Foundation
import Testing
@testable import JustTranscribeKit

/// A fake pasteboard and key sender, so tests never touch the real pasteboard or post events.
@MainActor
private final class PasteRecorder {
    var pasteboard: String?
    var keystrokes = 0
    var trusted = true
    var secureInput = false
    var secureInputChecks = 0
    var pasteboardWorks = true

    func paster() -> Paster {
        Paster(
            writePasteboard: { [self] in
                guard pasteboardWorks else { return false }
                pasteboard = $0
                return true
            },
            isAccessibilityTrusted: { [self] in trusted },
            isSecureInputEnabled: { [self] in secureInput },
            sendPasteKeystroke: { [self] in keystrokes += 1 },
            keystrokeDelay: .zero
        )
    }
}

@MainActor
struct PasterTests {
    @Test func trustedWithoutSecureInputPastesOnce() async {
        let recorder = PasteRecorder()
        #expect(await recorder.paster().paste("Привет 👋") == .pasted)
        #expect(recorder.pasteboard == "Привет 👋")
        #expect(recorder.keystrokes == 1)
    }

    @Test func secureInputCopiesOnly() async {
        let recorder = PasteRecorder()
        recorder.secureInput = true
        #expect(await recorder.paster().paste("secret") == .copiedOnly)
        #expect(recorder.pasteboard == "secret")
        #expect(recorder.keystrokes == 0)
    }

    @Test func untrustedCopiesOnly() async {
        let recorder = PasteRecorder()
        recorder.trusted = false
        #expect(await recorder.paster().paste("text") == .copiedOnly)
        #expect(recorder.pasteboard == "text")
        #expect(recorder.keystrokes == 0)
    }

    @Test func failedPasteboardWriteSendsNoKeystroke() async {
        let recorder = PasteRecorder()
        recorder.pasteboardWorks = false
        #expect(await recorder.paster().paste("text") == .copiedOnly)
        #expect(recorder.keystrokes == 0)
    }

    @Test func secureInputTurningOnDuringTheDelayCopiesOnly() async {
        let recorder = PasteRecorder()
        var paster = recorder.paster()
        paster.isSecureInputEnabled = {
            recorder.secureInputChecks += 1
            return recorder.secureInputChecks > 1
        }
        #expect(await paster.paste("text") == .copiedOnly)
        #expect(recorder.keystrokes == 0)
    }

    @Test func cancelDuringTheDelaySendsNoKeystroke() async {
        let recorder = PasteRecorder()
        var paster = recorder.paster()
        paster.keystrokeDelay = .seconds(30)
        let task = Task { await paster.paste("text") }
        task.cancel()
        #expect(await task.value == .copiedOnly)
        #expect(recorder.pasteboard == "text")
        #expect(recorder.keystrokes == 0)
    }
}

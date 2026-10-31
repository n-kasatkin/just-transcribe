import Accelerate
import Testing
@testable import JustTranscribeKit

struct SpeechGateTests {
    /// Durations in seconds of alternating quiet/loud runs, measured in 20 ms frames.
    private func runs(_ samples: [Float]) -> [(loud: Bool, seconds: Double)] {
        var result: [(loud: Bool, seconds: Double)] = []
        for start in stride(from: 0, to: samples.count, by: 320) {
            let frame = samples[start..<min(start + 320, samples.count)]
            let loud = frame.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) } >= 0.0056
            let seconds = Double(frame.count) / 16_000
            if let last = result.last, last.loud == loud {
                result[result.count - 1].seconds += seconds
            } else {
                result.append((loud, seconds))
            }
        }
        return result
    }

    @Test func longPausesShrinkAndSpeechStays() {
        let gap = Signals.noise(seconds: 1.5)
        let burst = Signals.tone(seconds: 0.5)
        let input = Signals.noise(seconds: 1, seed: 2) + burst + gap + burst + gap + burst + Signals.noise(seconds: 1, seed: 3)

        let gated = SpeechGate.apply(to: input)

        #expect(abs(gated.speechDuration - 1.5) < 0.001)
        let shape = runs(gated.samples)
        #expect(shape.map(\.loud) == [false, true, false, true, false, true, false])
        for run in shape {
            #expect(abs(run.seconds - (run.loud ? 0.5 : 0.3)) <= 0.021, "run \(run)")
        }
        #expect(abs(Double(gated.samples.count) / 16_000 - 2.7) < 0.001)
    }

    @Test func shortPausesAreKept() {
        let input = Signals.tone(seconds: 0.4) + Signals.noise(seconds: 0.4) + Signals.tone(seconds: 0.4)
        let gated = SpeechGate.apply(to: input)
        #expect(gated.samples == input)
        #expect(abs(gated.speechDuration - 0.8) < 0.001)
    }

    @Test func pureSilenceKeepsAtMostAPauseAndNoSpeech() {
        let gated = SpeechGate.apply(to: Signals.noise(seconds: 10))
        #expect(gated.speechDuration == 0)
        #expect(gated.samples.count == SpeechGate.keptPause)
        #expect(SpeechGate.apply(to: [Float](repeating: 0, count: 16_000)).speechDuration == 0)
        #expect(SpeechGate.apply(to: []) == GatedAudio(samples: [], speechDuration: 0))
    }

    @Test func cutsAreFaded() {
        let input = Signals.tone(seconds: 1, dbfs: -30) + Signals.tone(seconds: 0.5) + Signals.tone(seconds: 1, dbfs: -30)
        let gated = SpeechGate.apply(to: input)
        // The −30 dBFS tone is above the threshold, so nothing is cut and no fade is applied.
        #expect(gated.samples == input)

        let padded = Signals.noise(seconds: 1, dbfs: -50) + Signals.tone(seconds: 0.5) + Signals.noise(seconds: 1, dbfs: -50)
        let trimmed = SpeechGate.apply(to: padded).samples
        #expect(trimmed.first == 0)
        #expect(trimmed.last == 0)
    }
}

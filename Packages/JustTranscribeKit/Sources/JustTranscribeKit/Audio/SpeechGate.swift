import Accelerate

/// 16 kHz mono samples after pause trimming, and how much of the take was above the threshold.
public struct GatedAudio: Sendable, Equatable {
    public var samples: [Float]
    /// Seconds of 20 ms frames at or above `SpeechGate.thresholdDBFS`.
    public var speechDuration: Double
}

/// Shortens pauses the way the owner's ffmpeg `silenceremove` filter did: 20 ms frames, a fixed
/// −45 dBFS RMS threshold, pauses over 0.5 s cut to 0.3 s, 8 ms linear fades at every cut.
/// Leading and trailing silence keeps at most 0.3 s.
public enum SpeechGate {
    public static let sampleRate = 16_000
    public static let thresholdDBFS: Float = -45
    public static let frameLength = sampleRate / 50
    public static let maxPause = sampleRate / 2
    public static let keptPause = sampleRate * 3 / 10
    public static let fadeLength = sampleRate / 125

    public static func apply(to samples: [Float]) -> GatedAudio {
        let threshold = pow(10, thresholdDBFS / 20)
        let voiced = stride(from: 0, to: samples.count, by: frameLength).map { start in
            let end = min(start + frameLength, samples.count)
            return samples[start..<end].withUnsafeBufferPointer { vDSP.rootMeanSquare($0) } >= threshold
        }
        let speechDuration = Double(voiced.filter { $0 }.count * frameLength) / Double(sampleRate)

        guard let first = voiced.firstIndex(of: true), let last = voiced.lastIndex(of: true) else {
            return GatedAudio(samples: fadedOut(Array(samples.prefix(keptPause))), speechDuration: 0)
        }

        // Kept sample ranges; each interior long pause keeps its two ends, which overlap by one fade.
        let speechStart = first * frameLength
        let speechEnd = min((last + 1) * frameLength, samples.count)
        var ranges: [Range<Int>] = []
        var start = max(0, speechStart - keptPause)
        var frame = first
        while frame <= last {
            guard !voiced[frame] else { frame += 1; continue }
            let pauseStart = frame * frameLength
            while !voiced[frame] { frame += 1 }
            let pauseEnd = frame * frameLength
            if pauseEnd - pauseStart > maxPause {
                ranges.append(start..<(pauseStart + keptPause / 2 + fadeLength))
                start = pauseEnd - keptPause / 2
            }
        }
        ranges.append(start..<min(samples.count, speechEnd + keptPause))

        var out: [Float] = []
        out.reserveCapacity(ranges.reduce(0) { $0 + $1.count })
        for range in ranges {
            let overlap = out.isEmpty ? 0 : min(fadeLength, out.count, range.count)
            for i in 0..<overlap {
                let t = Float(i + 1) / Float(overlap + 1)
                let j = out.count - overlap + i
                out[j] = out[j] * (1 - t) + samples[range.lowerBound + i] * t
            }
            out.append(contentsOf: samples[(range.lowerBound + overlap)..<range.upperBound])
        }
        if ranges[0].lowerBound > 0 { out = fadedIn(out) }
        if ranges[ranges.count - 1].upperBound < samples.count { out = fadedOut(out) }
        return GatedAudio(samples: out, speechDuration: speechDuration)
    }

    private static func fadedIn(_ samples: [Float]) -> [Float] {
        var samples = samples
        let n = min(fadeLength, samples.count)
        for i in 0..<n { samples[i] *= Float(i) / Float(n) }
        return samples
    }

    private static func fadedOut(_ samples: [Float]) -> [Float] {
        var samples = samples
        let n = min(fadeLength, samples.count)
        for i in 0..<n { samples[samples.count - 1 - i] *= Float(i) / Float(n) }
        return samples
    }
}

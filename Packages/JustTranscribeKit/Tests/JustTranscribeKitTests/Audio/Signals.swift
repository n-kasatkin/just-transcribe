import Foundation

/// Deterministic synthetic 16 kHz test audio.
enum Signals {
    static let rate = 16_000

    /// A 300 Hz sine whose RMS is `dbfs`.
    static func tone(seconds: Double, dbfs: Float = -20, hz: Float = 300, rate: Int = rate) -> [Float] {
        let amplitude = pow(10, dbfs / 20) * 2.0.squareRoot().float
        return (0..<Int(seconds * Double(rate))).map { amplitude * sin(2 * .pi * hz * Float($0) / Float(rate)) }
    }

    /// Uniform white noise whose RMS is `dbfs`, from a fixed seed.
    static func noise(seconds: Double, dbfs: Float = -70, seed: UInt64 = 1) -> [Float] {
        let amplitude = pow(10, dbfs / 20) * 3.0.squareRoot().float
        var state = seed
        return (0..<Int(seconds * Double(rate))).map { _ in
            // SplitMix64
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return amplitude * (Float(z >> 40) / Float(1 << 24) * 2 - 1)
        }
    }

    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "jt-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private extension Double {
    var float: Float { Float(self) }
}

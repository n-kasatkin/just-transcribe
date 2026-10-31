import AVFoundation
import Testing
@testable import JustTranscribeKit

struct AudioFileTests {
    private func formatID(_ file: AVAudioFile) -> AudioFormatID {
        file.fileFormat.streamDescription.pointee.mFormatID
    }

    private func seconds(_ file: AVAudioFile) -> Double {
        Double(file.length) / file.fileFormat.sampleRate
    }

    private func audioDataBytes(_ url: URL) throws -> UInt64 {
        var id: AudioFileID?
        try #require(AudioFileOpenURL(url as CFURL, .readPermission, 0, &id) == noErr)
        defer { AudioFileClose(id!) }
        var bytes: UInt64 = 0
        var size = UInt32(MemoryLayout<UInt64>.size)
        try #require(AudioFileGetProperty(id!, kAudioFilePropertyAudioDataByteCount, &size, &bytes) == noErr)
        return bytes
    }

    @Test func writesAACm4a() throws {
        let url = try Signals.temporaryDirectory().appending(path: "take.m4a")
        // Noise keeps the encoder at its target rate; a pure tone needs far less.
        try AudioFileWriter.write(Signals.noise(seconds: 5, dbfs: -20), to: url, as: .m4a)

        let file = try AVAudioFile(forReading: url)
        #expect(formatID(file) == kAudioFormatMPEG4AAC)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(seconds(file) - 5) < 0.1)
        let bitRate = Double(try audioDataBytes(url) * 8) / seconds(file)
        #expect((28_000...36_000).contains(bitRate), "\(bitRate) bps")
    }

    @Test func writes16BitWAV() throws {
        let url = try Signals.temporaryDirectory().appending(path: "take.wav")
        try AudioFileWriter.write(Signals.tone(seconds: 2), to: url, as: .wav)

        let file = try AVAudioFile(forReading: url)
        #expect(formatID(file) == kAudioFormatLinearPCM)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(file.length == 32_000)
    }

    @Test func convertsM4aToWAVBesideIt() throws {
        let m4a = try Signals.temporaryDirectory().appending(path: "ostt-recording-20261031-120000-000.m4a")
        try AudioFileWriter.write(Signals.tone(seconds: 3), to: m4a, as: .m4a)

        let wav = try AudioConverter.wav(from: m4a)

        #expect(wav == m4a.deletingPathExtension().appendingPathExtension("wav"))
        let file = try AVAudioFile(forReading: wav)
        #expect(formatID(file) == kAudioFormatLinearPCM)
        #expect(file.fileFormat.commonFormat == .pcmFormatInt16)
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(seconds(file) - 3) < 0.1)
    }

    @Test func convertsFromOtherRatesAndChannels() throws {
        let dir = try Signals.temporaryDirectory()
        let source = dir.appending(path: "stereo.caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100))
            let tone = Signals.tone(seconds: 1, rate: 44_100)
            for channel in 0..<2 {
                tone.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: tone.count) }
            }
            buffer.frameLength = 44_100
            try file.write(from: buffer)
        }

        let file = try AVAudioFile(forReading: try AudioConverter.wav(from: source))
        #expect(file.fileFormat.sampleRate == 16_000)
        #expect(file.fileFormat.channelCount == 1)
        #expect(abs(seconds(file) - 1) < 0.01)
    }
}

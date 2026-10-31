import AVFoundation
import Foundation
import Testing
@testable import JustTranscribeKit

final class RetryTakeTests {
    private let directory: URL
    private let whisper = ActiveModel(providerID: "whisper", modelID: "base")
    private let cloud = ActiveModel(providerID: "elevenlabs", modelID: "scribe_v2")

    init() throws {
        directory = try Signals.temporaryDirectory()
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func conversionOnlyForM4aWithALocalModel() {
        let m4a = directory.appending(path: "ostt-recording-1.m4a")
        let wav = directory.appending(path: "ostt-recording-1.wav")
        #expect(RetryTake.needsWAVConversion(m4a, for: whisper))
        #expect(RetryTake.needsWAVConversion(m4a, for: ActiveModel(providerID: "command", modelID: "x")))
        #expect(!RetryTake.needsWAVConversion(wav, for: whisper))
        #expect(!RetryTake.needsWAVConversion(m4a, for: cloud))
        #expect(!RetryTake.needsWAVConversion(wav, for: cloud))
    }

    @Test func m4aIsConvertedForALocalModel() throws {
        let m4a = directory.appending(path: "ostt-recording-1.m4a")
        try AudioFileWriter.write(Signals.tone(seconds: 1.5), to: m4a, as: .m4a)
        let (file, duration) = try RetryTake.prepare(m4a, for: whisper)
        #expect(file == directory.appending(path: "ostt-recording-1.wav"))
        let format = try AVAudioFile(forReading: file).fileFormat
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
        #expect(duration > .milliseconds(1400) && duration < .milliseconds(1600))
    }

    @Test func m4aIsSentAsIsToACloudModel() throws {
        let m4a = directory.appending(path: "ostt-recording-2.m4a")
        try AudioFileWriter.write(Signals.tone(seconds: 1), to: m4a, as: .m4a)
        let (file, duration) = try RetryTake.prepare(m4a, for: cloud)
        #expect(file == m4a)
        #expect(duration > .milliseconds(900) && duration < .milliseconds(1100))
        #expect(!FileManager.default.fileExists(atPath: directory.appending(path: "ostt-recording-2.wav").path(percentEncoded: false)))
    }

    @Test func unreadableCLITakeIsSentAsIsToACloudModel() throws {
        // AVAudioFile cannot open this, as with an Ogg take from the ostt CLI.
        let ogg = directory.appending(path: "ostt-recording-3.ogg")
        try Data(count: 20_000).write(to: ogg)
        let (file, duration) = try RetryTake.prepare(ogg, for: cloud)
        #expect(file == ogg)
        #expect(duration == .seconds(20))
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            try RetryTake.prepare(self.directory.appending(path: "missing.wav"), for: self.whisper)
        }
        #expect(throws: (any Error).self) {
            try RetryTake.prepare(self.directory.appending(path: "missing.ogg"), for: self.cloud)
        }
    }
}

import Accelerate
import AVFoundation
import os

public enum RecorderError: Error, Sendable, Equatable {
    /// Microphone access is not granted; the app asks for it in onboarding, never here.
    case microphoneNotAuthorized
    /// No default input device, or its format cannot be converted.
    case noInputDevice
    /// `AVAudioEngine` failed to start; carries its description.
    case engineFailed(String)
}

/// Maps a buffer's RMS to the pill's 0...1 level: −55 dBFS and below is 0, −40 dBFS and above is 1.
public enum LevelMeter {
    public static func level(rms: Float) -> Double {
        let db = 20 * log10(max(rms, 1e-6))
        return Double(min(max((db + 55) / 15, 0), 1))
    }
}

/// Captures the default input device as 16 kHz mono Float samples and reports its level.
@MainActor
public final class Recorder {
    /// Called on the main actor about 30 times a second while recording, with a level in 0...1.
    public var onLevel: ((Double) -> Void)?

    private var engine: AVAudioEngine?
    private var buffer: RecordingBuffer?
    private var meter: Task<Void, Never>?

    public init() {}

    public var isRecording: Bool { engine != nil }

    /// Starts capturing; does nothing while already recording.
    public func start() throws {
        guard engine == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphoneNotAuthorized
        }
        // A fresh engine picks up the current default input device.
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0, let buffer = RecordingBuffer(inputFormat: format) else {
            throw RecorderError.noInputDevice
        }
        Self.installTap(on: input, format: format, into: buffer)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        self.buffer = buffer
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, let buffer = self.buffer else { return }
                self.onLevel?(buffer.level)
            }
        }
    }

    /// Stops capturing and returns everything recorded since `start()`.
    public func stop() -> [Float] {
        let samples = buffer?.finish() ?? []
        tearDown()
        return samples
    }

    /// Stops capturing and discards the recording.
    public func cancel() {
        tearDown()
    }

    private func tearDown() {
        meter?.cancel()
        meter = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        buffer = nil
        onLevel?(0)
    }

    // Nonisolated so the tap block is not main-actor isolated: it runs on the audio thread.
    private nonisolated static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, into buffer: RecordingBuffer) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { pcm, _ in
            buffer.append(pcm)
        }
    }
}

/// Accumulates converted samples from the audio thread and keeps the latest level.
final class RecordingBuffer: @unchecked Sendable {
    private struct State {
        var converter: SampleConverter
        var samples: [Float] = []
        var level: Double = 0
    }

    // Guards the non-Sendable converter and the samples; @unchecked rests on this lock.
    private let state: OSAllocatedUnfairLock<State>

    init?(inputFormat: AVAudioFormat) {
        guard let converter = SampleConverter(from: inputFormat) else { return nil }
        state = OSAllocatedUnfairLock(uncheckedState: State(converter: converter))
    }

    var level: Double { state.withLockUnchecked { $0.level } }

    func append(_ buffer: AVAudioPCMBuffer) {
        state.withLockUnchecked { state in
            let converted = state.converter.convert(buffer)
            guard !converted.isEmpty else { return }
            state.level = LevelMeter.level(rms: converted.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) })
            state.samples.append(contentsOf: converted)
        }
    }

    /// All samples so far, including those the resampler still held.
    func finish() -> [Float] {
        state.withLockUnchecked { state in
            state.samples.append(contentsOf: state.converter.finish())
            return state.samples
        }
    }
}

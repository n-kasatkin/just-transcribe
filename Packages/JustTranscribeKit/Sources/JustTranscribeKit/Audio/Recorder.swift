import Accelerate
import AVFoundation
import os

public enum RecorderError: Error, Sendable, Equatable {
    /// Microphone access is not granted; the app asks for it in onboarding, never here.
    case microphoneNotAuthorized
    /// No input device, or it reports no channels or no sample rate.
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

/// Captures the chosen input device, or the macOS default input while none is chosen or the chosen one
/// is not connected, as 16 kHz mono Float samples and reports its level.
@MainActor
public final class Recorder {
    /// Called on the main actor about 30 times a second while recording, with a level in 0...1.
    public var onLevel: ((Double) -> Void)?
    /// Called on the main actor when the audio hardware changed mid-recording and capture could not
    /// resume on the new input. Capture has ended: call `stop()` to keep the take so far, or `cancel()`.
    public var onInterrupted: (() -> Void)?

    /// The chosen input device's UID, read at each start and hardware change; nil means the macOS default.
    public var inputDeviceUID: () -> String? = { nil }

    private var engine: AVAudioEngine?
    private var buffer: RecordingBuffer?
    private var meter: Task<Void, Never>?
    private var configurationObserver: (any NSObjectProtocol)?

    public init() {}

    public var isRecording: Bool { engine != nil }

    /// Starts capturing; does nothing while already recording.
    public func start() throws {
        guard engine == nil else { return }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecorderError.microphoneNotAuthorized
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        selectInputDevice(on: input)
        guard Self.hasInput(input) else { throw RecorderError.noInputDevice }
        let buffer = RecordingBuffer()
        Self.installTap(on: input, into: buffer)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecorderError.engineFailed(error.localizedDescription)
        }
        self.engine = engine
        self.buffer = buffer
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        meter = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, let buffer = self.buffer else { return }
                self.onLevel?(buffer.level)
            }
        }
    }

    /// The engine stopped because the input or output hardware changed, as when a Bluetooth headset
    /// switches profile right after capture starts. Carries on in the same take; the buffer adapts to the new format.
    private func resume() {
        guard let engine, let buffer else { return }
        let input = engine.inputNode
        input.removeTap(onBus: 0)
        selectInputDevice(on: input)
        guard Self.hasInput(input) else {
            onInterrupted?()
            return
        }
        Self.installTap(on: input, into: buffer)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            onInterrupted?()
        }
    }

    /// Points `input` at the chosen device when it is connected, otherwise at the macOS default, so an
    /// unplugged device falls back mid-take too. The choice stays stored and is used again once it returns.
    private func selectInputDevice(on input: AVAudioInputNode) {
        guard let unit = input.audioUnit,
              var device = inputDeviceUID().flatMap(InputDevices.deviceID(uid:)) ?? InputDevices.defaultDeviceID()
        else { return }
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var current = AudioDeviceID(0)
        var currentSize = size
        // Setting the device it already uses would raise another configuration change.
        if AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &current, &currentSize) == noErr,
           current == device { return }
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, size)
    }

    /// Stops capturing and returns everything recorded since `start()`.
    public func stop() -> [Float] {
        let buffer = self.buffer
        // Remove the tap first so no callback converts after the stream is finished.
        tearDown()
        return buffer?.finish() ?? []
    }

    /// Stops capturing and discards the recording.
    public func cancel() {
        tearDown()
    }

    private func tearDown() {
        meter?.cancel()
        meter = nil
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        buffer = nil
        onLevel?(0)
    }

    /// False when the hardware side or the tapped side reports no channels or no sample rate; tapping
    /// an empty format raises an exception Swift cannot catch.
    private static func hasInput(_ input: AVAudioInputNode) -> Bool {
        [input.inputFormat(forBus: 0), input.outputFormat(forBus: 0)].allSatisfy { $0.sampleRate > 0 && $0.channelCount > 0 }
    }

    // Nonisolated so the tap block is not main-actor isolated: it runs on the audio thread.
    // A nil format taps the node's own format, so a device switch can never raise a format-mismatch
    // exception; the buffer converts whatever rate and channel count arrives.
    private nonisolated static func installTap(on input: AVAudioInputNode, into buffer: RecordingBuffer) {
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { pcm, _ in
            buffer.append(pcm)
        }
    }
}

/// Accumulates converted samples from the audio thread and keeps the latest level. Buffers of any
/// sample rate and channel count are accepted; a format change mid-take starts a new converter.
final class RecordingBuffer: @unchecked Sendable {
    private struct State {
        var converter: SampleConverter?
        var samples: [Float] = []
        var level: Double = 0

        /// Moves the samples the resampler still holds into `samples`.
        mutating func flush() {
            samples.append(contentsOf: (try? converter?.finish()) ?? [])
        }
    }

    // Guards the non-Sendable converter and the samples; @unchecked rests on this lock.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    var level: Double { state.withLockUnchecked { $0.level } }

    /// Converts and keeps `buffer`; a buffer that cannot be converted is dropped, as the audio
    /// thread has nobody to report to.
    func append(_ buffer: AVAudioPCMBuffer) {
        state.withLockUnchecked { state in
            if state.converter?.inputFormat != buffer.format {
                state.flush()
                state.converter = SampleConverter(from: buffer.format)
            }
            guard let converted = try? state.converter?.convert(buffer), !converted.isEmpty else { return }
            state.level = LevelMeter.level(rms: converted.withUnsafeBufferPointer { vDSP.rootMeanSquare($0) })
            state.samples.append(contentsOf: converted)
        }
    }

    /// All samples so far, including those the resampler still held.
    func finish() -> [Float] {
        state.withLockUnchecked { state in
            state.flush()
            return state.samples
        }
    }
}

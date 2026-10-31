import Foundation

/// Where a dictation is: the hotkey, Escape and the menu act on this.
public enum DictationPhase: Sendable, Equatable {
    case idle
    case recording
    case transcribing

    /// Escape is registered only while busy, so it works normally in other apps otherwise.
    public var isBusy: Bool { self != .idle }

    /// The dictation hotkey: start, then stop and transcribe. A press while transcribing is ignored.
    public var onToggle: DictationCommand {
        switch self {
        case .idle: .start
        case .recording: .stopAndTranscribe
        case .transcribing: .none
        }
    }

    /// Escape discards a recording or kills the running ostt.
    public var onEscape: DictationCommand {
        switch self {
        case .idle: .none
        case .recording: .discardRecording
        case .transcribing: .cancelTranscription
        }
    }

    /// The input device went away mid-recording: keep what was captured and transcribe it.
    public var onInterrupted: DictationCommand {
        self == .recording ? .stopAndTranscribe : .none
    }

    /// Retry and other menu actions that start ostt wait until nothing else runs.
    public var canRetry: Bool { self == .idle }
}

public enum DictationCommand: Sendable, Equatable {
    case none
    case start
    case stopAndTranscribe
    case discardRecording
    case cancelTranscription
}

public enum DictationError: Error, Sendable, Equatable {
    /// The user denied microphone access, or it is restricted.
    case microphoneDenied
    /// `ostt model current` reports no model.
    case noModel
    /// Retry found no recording in ostt's folder.
    case noRecording
}

/// What the pill shows when a step ends.
public enum DictationFeedback: Sendable, Equatable {
    case hidden
    /// A short white label.
    case notice(String)
    /// Red bars and a label of at most three words.
    case error(String)

    public static let nothingHeard = DictationFeedback.notice("Nothing heard")
    public static let copied = DictationFeedback.notice("Copied")

    public static func paste(_ outcome: Paster.Outcome) -> DictationFeedback {
        switch outcome {
        case .pasted: .hidden
        case .copiedOnly: .copied
        }
    }

    /// The pill for a failed step; a cancelled step just hides it.
    public static func failure(_ error: any Error) -> DictationFeedback {
        switch error {
        case OsttError.cancelled, is CancellationError:
            .hidden
        case OsttError.failed(let result):
            .error(result.lastErrorLine.map { shortLabel($0) } ?? "ostt failed")
        case OsttError.timedOut:
            .error("Timed out")
        case OsttError.helperMissing:
            .error("ostt missing")
        case Transcriber.Failure.emptyTranscript:
            nothingHeard
        case DictationError.microphoneDenied, RecorderError.microphoneNotAuthorized:
            .error("Microphone access needed")
        case DictationError.noModel:
            .error("No engine")
        case DictationError.noRecording:
            .notice("No recording")
        case RecorderError.noInputDevice:
            .error("No microphone")
        case RecorderError.engineFailed:
            .error("Microphone failed")
        case is ActiveModel.ParseError:
            .error("Unknown engine")
        default:
            .error("Something went wrong")
        }
    }

    /// ostt's stderr line cut to `maxWords`: no ANSI colours, no anyhow "Error:" or "0:" cause
    /// prefix, no trailing punctuation, first letter capitalised.
    public static func shortLabel(_ line: String, maxWords: Int = 3) -> String {
        let plain = line.replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
        var words = plain.split(whereSeparator: \.isWhitespace).map(String.init)
        while let first = words.first, first.lowercased() == "error:" || first.wholeMatch(of: /\d+:/) != nil {
            words.removeFirst()
        }
        var label = words.prefix(maxWords).joined(separator: " ")
        while let last = label.last, ":,;.".contains(last) {
            label.removeLast()
        }
        guard let first = label.first else { return "ostt failed" }
        return first.uppercased() + label.dropFirst()
    }
}

extension AudioContainer {
    /// The file container ostt should get for an engine's input format.
    public init(_ format: EngineAudioFormat) {
        switch format {
        case .m4a: self = .m4a
        case .wav: self = .wav
        }
    }
}

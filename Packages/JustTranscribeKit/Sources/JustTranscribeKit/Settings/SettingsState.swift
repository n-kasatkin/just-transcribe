import Foundation

/// A value fetched from ostt, with the error text to show when that failed.
public enum Loadable<Value> {
    case idle, loading, loaded(Value), failed(String)

    public var value: Value? {
        if case .loaded(let value) = self { value } else { nil }
    }
}

extension Loadable: Sendable where Value: Sendable {}
extension Loadable: Equatable where Value: Equatable {}

/// The Settings window's pure state rules, kept here so `swift test` covers them.
public enum SettingsState {
    public static let registryUnavailable = "Couldn't load the model list. Check the connection and retry."
    public static let registryTimedOut = "The model list did not load within 20 seconds. Check the connection and retry."

    /// One local `model list` result, split into the Whisper and Parakeet sections. ostt prints `[]` and
    /// exits 0 when the registry fetch fails with no cache, so an empty section is an error with Retry.
    public static func localModels(
        _ result: Result<[String: [OsttModel]], any Error>
    ) -> [String: Loadable<[OsttModel]>] {
        var sections: [String: Loadable<[OsttModel]>] = [:]
        for provider in OsttProvider.local {
            sections[provider.id] = switch result {
            case .success(let lists):
                lists[provider.id].flatMap { $0.isEmpty ? nil : .loaded($0) } ?? .failed(registryUnavailable)
            case .failure(OsttError.timedOut):
                .failed(registryTimedOut)
            case .failure(let error):
                .failed(message(for: error))
            }
        }
        return sections
    }

    /// The selected model belongs to a cloud provider with no saved key (Decision 4).
    public static func currentModelMissingKey(_ current: OsttModelID?, providersWithKeys: Set<String>) -> Bool {
        guard let current, OsttProvider.withID(current.provider)?.needsKey == true else { return false }
        return !providersWithKeys.contains(current.provider)
    }

    /// The one-line text shown for a failed settings action.
    public static func message(for error: any Error) -> String {
        switch error {
        case OsttError.failed(let result):
            result.lastErrorLine ?? "ostt exited with status \(result.exitCode)."
        case OsttError.timedOut:
            "ostt did not answer within 20 seconds."
        case OsttError.helperMissing:
            "The bundled ostt helper is missing. Reinstall just transcribe."
        case OsttError.cancelled:
            "Cancelled."
        case OsttSettingsError.downloadStalled:
            "The download stalled: no progress for 60 seconds."
        case OsttSettingsError.unexpectedOutput:
            "ostt returned output this version of just transcribe cannot read."
        case CredentialsStore.Failure.multilineKey:
            "The key must be on one line."
        case CredentialsStore.Failure.unreadableFile:
            "ostt's credentials file is not plain text, so it was left unchanged."
        case CredentialsStore.Failure.unrecognizedEntry(let provider):
            "ostt's credentials file has a \(provider) line in a form just transcribe does not edit, so it was left unchanged."
        default:
            error.localizedDescription
        }
    }
}

/// Downloads in flight and their latest progress (nil until ostt reports any).
public struct ActiveDownloads: Sendable, Equatable {
    public private(set) var progress: [OsttModelID: DownloadProgress?] = [:]

    public init() {}

    /// False when this model is already downloading.
    public mutating func start(_ id: OsttModelID) -> Bool {
        guard progress[id] == nil else { return false }
        progress[id] = .some(nil)
        return true
    }

    /// Progress reported after `finish` is dropped, so a finished row does not come back.
    public mutating func update(_ id: OsttModelID, _ update: DownloadProgress) {
        if progress[id] != nil { progress[id] = update }
    }

    public mutating func finish(_ id: OsttModelID) {
        progress[id] = nil
    }

    public func isDownloading(_ id: OsttModelID) -> Bool {
        progress[id] != nil
    }
}

import Foundation
import Observation

/// Every successful transcript, newest first, in a JSON file of the app's own. Each change is
/// written at once, atomically.
@MainActor
@Observable
public final class HistoryStore {
    public struct Entry: Codable, Identifiable, Equatable, Sendable {
        public var id: UUID
        public var date: Date
        public var text: String

        public init(id: UUID = UUID(), date: Date, text: String) {
            self.id = id
            self.date = date
            self.text = text
        }
    }

    public static let capacity = 500

    /// `~/Library/Application Support/just transcribe/history.json`.
    public static var defaultFile: URL {
        URL.applicationSupportDirectory.appending(path: "just transcribe/history.json", directoryHint: .notDirectory)
    }

    public private(set) var entries: [Entry]
    /// Why the last read or write failed, shown on the History tab.
    public private(set) var error: String?

    @ObservationIgnored public let file: URL

    /// A missing file starts an empty history. An unreadable one also does, after it is moved aside
    /// as `history-unreadable-<time>.json`, so the next change cannot overwrite it.
    public init(file: URL = HistoryStore.defaultFile) {
        self.file = file
        entries = []
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        do {
            entries = try Self.decoder.decode([Entry].self, from: Data(contentsOf: file))
        } catch {
            let stamp = Int(Date.now.timeIntervalSince1970)
            let aside = file.deletingLastPathComponent().appending(path: "history-unreadable-\(stamp).json")
            let kept = (try? FileManager.default.moveItem(at: file, to: aside)) != nil
            self.error = kept
                ? "Couldn't read the history; it was kept as \(aside.lastPathComponent)."
                : "Couldn't read the history: \(error.localizedDescription)"
        }
    }

    public func add(_ text: String, date: Date = .now) {
        entries.insert(Entry(date: date, text: text), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
        save()
    }

    public func removeOlder(than cutoff: Date) {
        let kept = entries.filter { $0.date >= cutoff }
        guard kept.count != entries.count else { return }
        entries = kept
        save()
    }

    public func clear() {
        entries = []
        save()
    }

    private func save() {
        let directory = file.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path(percentEncoded: false))
            // The atomic write creates the file with the default mode; the 0700 folder keeps it private until the chmod.
            try Self.encoder.encode(entries).write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
            self.error = nil
        } catch {
            self.error = "Couldn't save the history: \(error.localizedDescription)"
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

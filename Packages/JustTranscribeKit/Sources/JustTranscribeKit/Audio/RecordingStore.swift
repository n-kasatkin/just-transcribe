import Foundation

/// ostt's recordings directory, shared with the CLI so `ostt retry` sees the app's takes.
/// Names follow ostt (`src/recording/storage.rs`), which sorts by name to find the newest.
public struct RecordingStore: Sendable {
    public static let prefix = "ostt-recording-"
    public static let keptCount = 10

    public var directory: URL

    public init(paths: OsttPaths) {
        directory = paths.recordingsDirectory
    }

    /// A new file URL `ostt-recording-YYYYmmdd-HHMMSS-mmm.<ext>` in local time; creates the
    /// directory with mode 0700 when it is missing, as ostt does.
    public func newRecordingURL(
        _ container: AudioContainer, date: Date = .now, timeZone: TimeZone = .current
    ) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let name = "\(Self.prefix)\(formatter.string(from: date)).\(container.fileExtension)"
        return directory.appending(path: name, directoryHint: .notDirectory)
    }

    /// ostt's recording files, newest first; empty when the directory is missing.
    public func recordings() -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []
        return names
            .filter { $0.hasPrefix(Self.prefix) }
            .sorted(by: >)
            .map { directory.appending(path: $0, directoryHint: .notDirectory) }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    }

    public func latestRecording() -> URL? {
        recordings().first
    }

    /// Deletes all but the newest `keeping` recordings; other files are never touched.
    public func prune(keeping: Int = keptCount) throws {
        for url in recordings().dropFirst(keeping) {
            try FileManager.default.removeItem(at: url)
        }
    }
}

import Foundation

/// The folder takes are saved to: ostt's recordings directory by default, shared with the CLI so
/// `ostt retry` sees the app's takes. Names follow ostt (`src/recording/storage.rs`), which sorts by
/// name to find the newest.
public struct RecordingStore: Sendable {
    public static let prefix = "ostt-recording-"

    public enum Failure: Error, Equatable, Sendable {
        /// The folder cannot be created or written; holds its path.
        case folderUnavailable(String)
    }

    public var directory: URL
    /// ostt's own folder is made private even when it exists; a folder the user chose keeps its mode.
    public var isOsttFolder: Bool

    /// A folder the user chose.
    public init(directory: URL) {
        self.directory = directory
        isOsttFolder = false
    }

    public init(paths: OsttPaths) {
        directory = paths.recordingsDirectory
        isOsttFolder = true
    }

    /// Creates the directory if needed with mode 0700, as ostt does, and checks it is writable.
    public func prepareDirectory() throws {
        let path = directory.path(percentEncoded: false)
        do {
            let existed = FileManager.default.fileExists(atPath: path)
            // Parents get the default mode; only the recordings folder is private.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if !existed || isOsttFolder {
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            }
        } catch {
            throw Failure.folderUnavailable(path)
        }
        guard FileManager.default.isWritableFile(atPath: path) else { throw Failure.folderUnavailable(path) }
    }

    /// A new file URL `ostt-recording-YYYYmmdd-HHMMSS-mmm.<ext>` in local time, in a prepared directory.
    public func newRecordingURL(
        _ container: AudioContainer, date: Date = .now, timeZone: TimeZone = .current
    ) throws -> URL {
        try prepareDirectory()
        let name = "\(Self.prefix)\(Self.nameFormatter(timeZone).string(from: date)).\(container.fileExtension)"
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

    /// Deletes recordings made before `cutoff`; other files are never touched. A file that cannot
    /// be deleted is skipped: the CLI cleans the same folder, so one can vanish under us.
    public func deleteRecordings(olderThan cutoff: Date, timeZone: TimeZone = .current) {
        for url in recordings() {
            // The name's time first: Retry's WAV copy of an old take is a new file with the take's name.
            let created = Self.date(fromName: url.lastPathComponent, timeZone: timeZone)
                ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate)
            if let created, created < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// The time in a recording's name.
    public static func date(fromName name: String, timeZone: TimeZone = .current) -> Date? {
        guard name.hasPrefix(prefix) else { return nil }
        let stamp = name.dropFirst(prefix.count).prefix(while: { $0 != "." })
        return nameFormatter(timeZone).date(from: String(stamp))
    }

    private static func nameFormatter(_ timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter
    }
}

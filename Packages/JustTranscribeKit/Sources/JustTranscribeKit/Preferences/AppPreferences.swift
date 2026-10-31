import Foundation

/// How long recordings or history entries are kept.
public enum RetentionPeriod: Int, CaseIterable, Identifiable, Sendable {
    case oneDay = 1
    case threeDays = 3
    case sevenDays = 7
    case thirtyDays = 30
    case never = 0

    public var id: Int { rawValue }

    /// Items dated before this are deleted; nil keeps everything.
    public func cutoff(before now: Date) -> Date? {
        self == .never ? nil : now.addingTimeInterval(-Double(rawValue) * 86_400)
    }

    public var title: String {
        switch self {
        case .oneDay: "1 day"
        case .never: "Forever"
        default: "\(rawValue) days"
        }
    }
}

/// The app's own settings in UserDefaults. Settings views write the same keys through `@AppStorage`.
/// Unchecked: UserDefaults is thread-safe, and the save runs off the main actor.
public struct AppPreferences: @unchecked Sendable {
    public static let recordingRetentionKey = "recordingRetentionDays"
    public static let historyRetentionKey = "historyRetentionDays"
    /// A folder path; missing or empty means ostt's recordings directory.
    public static let recordingsFolderKey = "recordingsFolder"
    /// Custom folders used before the current one; retention keeps cleaning them.
    public static let pastRecordingsFoldersKey = "pastRecordingsFolders"
    public static let showMenuBarIconKey = "showMenuBarIcon"
    /// Set once the user confirmed hiding the icon, so the explanation shows only the first time.
    public static let hideMenuBarIconConfirmedKey = "hideMenuBarIconConfirmed"

    public static let defaultRecordingRetention = RetentionPeriod.threeDays
    public static let defaultHistoryRetention = RetentionPeriod.thirtyDays

    public let defaults: UserDefaults
    public let paths: OsttPaths

    public init(defaults: UserDefaults = .standard, paths: OsttPaths) {
        self.defaults = defaults
        self.paths = paths
    }

    public var recordingRetention: RetentionPeriod {
        retention(Self.recordingRetentionKey) ?? Self.defaultRecordingRetention
    }

    public var historyRetention: RetentionPeriod {
        retention(Self.historyRetentionKey) ?? Self.defaultHistoryRetention
    }

    public var showMenuBarIcon: Bool {
        defaults.object(forKey: Self.showMenuBarIconKey) as? Bool ?? true
    }

    /// The chosen folder, or ostt's when none is set. Read at each use, so a change applies to the next take.
    public var recordingsDirectory: URL {
        Self.recordingsDirectory(customPath: defaults.string(forKey: Self.recordingsFolderKey), paths: paths)
    }

    public var recordingStore: RecordingStore {
        Self.recordingStore(customPath: defaults.string(forKey: Self.recordingsFolderKey), paths: paths)
    }

    /// Every folder retention cleans: the current one, ostt's and earlier choices, so a folder change
    /// leaves no take behind for good.
    public var cleanedRecordingStores: [RecordingStore] {
        let past = (defaults.stringArray(forKey: Self.pastRecordingsFoldersKey) ?? []).map {
            Self.recordingStore(customPath: $0, paths: paths)
        }
        var seen = Set<URL>()
        return ([recordingStore, RecordingStore(paths: paths)] + past).filter {
            seen.insert($0.directory.standardizedFileURL).inserted
        }
    }

    /// Records the folder being left, so retention keeps cleaning it.
    public func leaveRecordingsFolder(_ customPath: String) {
        guard !customPath.isEmpty else { return }
        let past = defaults.stringArray(forKey: Self.pastRecordingsFoldersKey) ?? []
        guard !past.contains(customPath) else { return }
        defaults.set(past + [customPath], forKey: Self.pastRecordingsFoldersKey)
    }

    private static func recordingStore(customPath: String?, paths: OsttPaths) -> RecordingStore {
        guard let customPath, !customPath.isEmpty else { return RecordingStore(paths: paths) }
        return RecordingStore(directory: recordingsDirectory(customPath: customPath, paths: paths))
    }

    public static func recordingsDirectory(customPath: String?, paths: OsttPaths) -> URL {
        guard let customPath, !customPath.isEmpty else { return paths.recordingsDirectory }
        return URL(filePath: customPath, directoryHint: .isDirectory)
    }

    private func retention(_ key: String) -> RetentionPeriod? {
        (defaults.object(forKey: key) as? Int).flatMap(RetentionPeriod.init(rawValue:))
    }
}

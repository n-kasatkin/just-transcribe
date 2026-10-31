import Foundation

/// ostt's own file locations (`src/app_dirs.rs`), so the app and the ostt CLI share keys,
/// keywords, models and recordings.
public struct OsttPaths: Sendable, Equatable {
    /// `$XDG_CONFIG_HOME/ostt`, else `~/.config/ostt`.
    public var configDirectory: URL
    /// `$XDG_DATA_HOME/ostt`, else `~/.local/share/ostt`.
    public var dataDirectory: URL

    public init(configDirectory: URL, dataDirectory: URL) {
        self.configDirectory = configDirectory
        self.dataDirectory = dataDirectory
    }

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let home = environment["HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0, directoryHint: .isDirectory) } ?? home
        configDirectory = Self.directory(environment["XDG_CONFIG_HOME"], fallback: home.appending(path: ".config"))
        dataDirectory = Self.directory(environment["XDG_DATA_HOME"], fallback: home.appending(path: ".local/share"))
    }

    public var configFile: URL { configDirectory.appending(path: "ostt.toml") }
    public var credentialsFile: URL { dataDirectory.appending(path: "credentials") }
    public var recordingsDirectory: URL { dataDirectory.appending(path: "recordings", directoryHint: .isDirectory) }
    public var modelsDirectory: URL { dataDirectory.appending(path: "models", directoryHint: .isDirectory) }

    // ostt uses any set XDG value as is, even an empty one.
    private static func directory(_ xdg: String?, fallback: URL) -> URL {
        let base = xdg.map { URL(filePath: $0, directoryHint: .isDirectory) } ?? fallback
        return base.appending(path: "ostt", directoryHint: .isDirectory)
    }
}

import Foundation

/// The ostt binary bundled at `Contents/Helpers/ostt` and the environment every ostt call runs with.
public enum OsttHelper {
    /// Directories ostt's `command` provider and its tools may live in. A GUI app inherits only
    /// the system part, so the Homebrew prefixes are added.
    public static let requiredPath = [
        "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    /// The executable ostt inside `bundleURL`, or nil when it is missing or not executable.
    public static func locate(in bundleURL: URL, fileManager: FileManager = .default) -> URL? {
        let url = bundleURL.appending(path: "Contents/Helpers/ostt", directoryHint: .notDirectory)
        return fileManager.isExecutableFile(atPath: url.path(percentEncoded: false)) ? url : nil
    }

    /// `base` with a UTF-8 English locale, so ostt's output and messages parse the same everywhere,
    /// and a PATH that keeps the inherited entries first and appends any missing `requiredPath` entry.
    public static func environment(
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = base
        env["LANG"] = "en_US.UTF-8"
        env["LC_ALL"] = "en_US.UTF-8"
        var path = (base["PATH"] ?? "").split(separator: ":").map(String.init)
        for dir in requiredPath where !path.contains(dir) {
            path.append(dir)
        }
        env["PATH"] = path.joined(separator: ":")
        return env
    }
}

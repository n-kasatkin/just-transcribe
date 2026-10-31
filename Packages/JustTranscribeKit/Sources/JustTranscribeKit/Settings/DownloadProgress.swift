/// One progress update of `ostt model local download`.
public struct DownloadProgress: Sendable, Equatable {
    /// 0...1, or nil when ostt does not know the total size.
    public var fraction: Double?
    /// As ostt formats it, e.g. "120 MB" or "1.2 GB".
    public var downloaded: String
    public var total: String?
    public var megabytesPerSecond: Double

    public init(fraction: Double?, downloaded: String, total: String?, megabytesPerSecond: Double) {
        self.fraction = fraction
        self.downloaded = downloaded
        self.total = total
        self.megabytesPerSecond = megabytesPerSecond
    }
}

/// Reads ostt's stderr progress (`print_download_progress`, `src/commands/model.rs`), which redraws one
/// line with `\r` in two forms: `\r NN.N%  X / Y  Z MB/s`, or `\rX downloaded  Z MB/s` when the server
/// sends no size. Chunks may split a line anywhere.
struct DownloadProgressParser {
    private var pending = ""

    /// The newest complete update in the text so far, or nil when `chunk` finished none.
    mutating func feed(_ chunk: String) -> DownloadProgress? {
        let pieces = (pending + chunk).split(omittingEmptySubsequences: false) { $0 == "\r" || $0 == "\n" }
        let tail = String(pieces.last ?? "")
        // Every update ends in "MB/s", so a cut-off one never parses; a tail that does is complete
        // and is not kept, or the next separator would report it twice.
        if let update = Self.parse(tail) {
            pending = ""
            return update
        }
        pending = tail
        return pieces.dropLast().reversed().lazy.compactMap { Self.parse(String($0)) }.first
    }

    static func parse(_ line: String) -> DownloadProgress? {
        if let match = line.wholeMatch(of: #/\s*(\d+(?:\.\d+)?)%\s+(\d+(?:\.\d+)? [KMG]?B) / (\d+(?:\.\d+)? [KMG]?B)\s+(\d+(?:\.\d+)?) MB/s\s*/#),
           let percent = Double(match.1), let speed = Double(match.4) {
            return DownloadProgress(fraction: min(max(percent / 100, 0), 1), downloaded: String(match.2),
                                    total: String(match.3), megabytesPerSecond: speed)
        }
        if let match = line.wholeMatch(of: #/\s*(\d+(?:\.\d+)? [KMG]?B) downloaded\s+(\d+(?:\.\d+)?) MB/s\s*/#),
           let speed = Double(match.2) {
            return DownloadProgress(fraction: nil, downloaded: String(match.1), total: nil, megabytesPerSecond: speed)
        }
        return nil
    }
}

import Foundation

/// `ostt model current`, asked again only when `ostt.toml` changed on disk or `invalidate()` ran,
/// so starting a dictation usually costs no ostt launch.
public actor ActiveModelCache {
    private let runner: any OsttRunning
    private let configFile: URL
    private var entry: (modified: Date?, model: ActiveModel?)?
    /// Bumped by `invalidate()`, so a query that was running then does not store its stale answer.
    private var generation = 0

    public init(runner: any OsttRunning, configFile: URL) {
        self.runner = runner
        self.configFile = configFile
    }

    public func current() async throws -> ActiveModel? {
        // Read before the query: a change made while it runs then triggers one more query, never a stale hit.
        let modified = modificationDate()
        if let entry, entry.modified == modified { return entry.model }
        let started = generation
        let model = try await ActiveModel.current(using: runner)
        if generation == started { entry = (modified, model) }
        return model
    }

    public func invalidate() {
        entry = nil
        generation += 1
    }

    // Not `URL.resourceValues`: it caches per URL and would keep returning the first date.
    private func modificationDate() -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: configFile.path(percentEncoded: false))
        return attributes?[.modificationDate] as? Date
    }
}

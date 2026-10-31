import Foundation
import Testing
@testable import JustTranscribeKit

/// Runs the real ostt from `vendor/ostt` (fetched by `scripts/fetch-ostt.sh`) in throwaway XDG dirs.
struct BundledOsttSmokeTests {
    private static let repoRoot = URL(filePath: #filePath)
        .deletingLastPathComponent() // Engine
        .deletingLastPathComponent() // JustTranscribeKitTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // JustTranscribeKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent()

    @Test func freshConfigHasNoActiveModel() async throws {
        let ostt = Self.repoRoot.appending(path: "vendor/ostt/ostt")
        try #require(
            FileManager.default.isExecutableFile(atPath: ostt.path(percentEncoded: false)),
            "Missing \(ostt.path(percentEncoded: false)); run scripts/fetch-ostt.sh"
        )
        let home = FileManager.default.temporaryDirectory
            .appending(path: "jt-smoke-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let runner = ProcessOsttRunner(executableURL: ostt, extraEnvironment: isolatedEnvironment(in: home))
        #expect(try await ActiveModel.current(using: runner) == nil)
    }
}

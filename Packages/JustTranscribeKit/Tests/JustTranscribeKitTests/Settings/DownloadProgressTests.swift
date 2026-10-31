import Testing
@testable import JustTranscribeKit

struct DownloadProgressTests {
    @Test func parsesKnownTotalForm() {
        #expect(DownloadProgressParser.parse("  5.0%  27 MB / 547 MB  12.3 MB/s")
            == DownloadProgress(fraction: 0.05, downloaded: "27 MB", total: "547 MB", megabytesPerSecond: 12.3))
        #expect(DownloadProgressParser.parse("100.0%  1.5 GB / 1.5 GB  80.0 MB/s")?.fraction == 1)
    }

    @Test func parsesUnknownTotalForm() {
        #expect(DownloadProgressParser.parse("1.2 GB downloaded  3.4 MB/s")
            == DownloadProgress(fraction: nil, downloaded: "1.2 GB", total: nil, megabytesPerSecond: 3.4))
    }

    @Test func ignoresOtherLines() {
        #expect(DownloadProgressParser.parse("Downloading local model: whisper/base") == nil)
        #expect(DownloadProgressParser.parse(" 12.5%  27 MB / 547 MB  12") == nil)
        #expect(DownloadProgressParser.parse("") == nil)
    }

    @Test func followsRedrawnLineAcrossChunks() {
        var parser = DownloadProgressParser()
        #expect(parser.feed("Downloading local model: whisper/base\n") == nil)
        #expect(parser.feed("\r  1.0%  1 MB / 142 MB  1.0 MB/s\r  2.0%  3 MB / 14") == DownloadProgress(
            fraction: 0.01, downloaded: "1 MB", total: "142 MB", megabytesPerSecond: 1))
        #expect(parser.feed("2 MB  2.5 MB/s") == DownloadProgress(
            fraction: 0.02, downloaded: "3 MB", total: "142 MB", megabytesPerSecond: 2.5))
        #expect(parser.feed("\r150 MB downloaded  9.9 MB/s\n") == DownloadProgress(
            fraction: nil, downloaded: "150 MB", total: nil, megabytesPerSecond: 9.9))
        #expect(parser.feed("\n") == nil)
    }
}

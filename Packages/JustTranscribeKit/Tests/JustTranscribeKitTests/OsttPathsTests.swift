import Foundation
import Testing
@testable import JustTranscribeKit

struct OsttPathsTests {
    let home = URL(filePath: "/home/test", directoryHint: .isDirectory)

    @Test func defaultsFollowHome() {
        let paths = OsttPaths(environment: ["HOME": "/home/test"], home: URL(filePath: "/elsewhere"))
        #expect(paths.configFile.path() == "/home/test/.config/ostt/ostt.toml")
        #expect(paths.credentialsFile.path() == "/home/test/.local/share/ostt/credentials")
        #expect(paths.recordingsDirectory.path() == "/home/test/.local/share/ostt/recordings/")
        #expect(paths.modelsDirectory.path() == "/home/test/.local/share/ostt/models/")
    }

    @Test func xdgOverridesWin() {
        let paths = OsttPaths(environment: ["XDG_CONFIG_HOME": "/x/cfg", "XDG_DATA_HOME": "/x/data"], home: home)
        #expect(paths.configFile.path() == "/x/cfg/ostt/ostt.toml")
        #expect(paths.credentialsFile.path() == "/x/data/ostt/credentials")
    }

    @Test func lastErrorLineSkipsBlankAndProgressLines() {
        let result = OsttResult(exitCode: 1, stdout: "", stderr: "warn\r 10.0%\nError: 401 Unauthorized \n\n")
        #expect(result.lastErrorLine == "Error: 401 Unauthorized")
        #expect(OsttResult(exitCode: 1, stdout: "", stderr: " \n").lastErrorLine == nil)
    }
}

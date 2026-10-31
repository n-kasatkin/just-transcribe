import Foundation
import Testing
@testable import JustTranscribeKit

struct OsttHelperTests {
    private func makeBundle(helperPermissions: Int16?) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appending(path: "jt-\(UUID().uuidString)/just transcribe.app", directoryHint: .isDirectory)
        let helpers = bundle.appending(path: "Contents/Helpers", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        if let helperPermissions {
            let ostt = helpers.appending(path: "ostt").path(percentEncoded: false)
            #expect(FileManager.default.createFile(
                atPath: ostt, contents: Data("#!/bin/sh\n".utf8),
                attributes: [.posixPermissions: helperPermissions]
            ))
        }
        return bundle
    }

    @Test func locatesExecutableHelper() throws {
        let bundle = try makeBundle(helperPermissions: 0o755)
        let url = try #require(OsttHelper.locate(in: bundle))
        #expect(url.path(percentEncoded: false).hasSuffix("just transcribe.app/Contents/Helpers/ostt"))
    }

    @Test func missingHelperIsNil() throws {
        #expect(OsttHelper.locate(in: try makeBundle(helperPermissions: nil)) == nil)
    }

    @Test func nonExecutableHelperIsNil() throws {
        #expect(OsttHelper.locate(in: try makeBundle(helperPermissions: 0o644)) == nil)
    }

    @Test func setsUTF8EnglishLocale() {
        let env = OsttHelper.environment(inheriting: ["LANG": "ru_RU.UTF-8", "LC_ALL": "C"])
        #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["LC_ALL"] == "en_US.UTF-8")
    }

    @Test func extendsGUIPathWithHomebrew() {
        let env = OsttHelper.environment(inheriting: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        #expect(env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin")
    }

    @Test func keepsInheritedPathOrderWithoutDuplicates() {
        let env = OsttHelper.environment(inheriting: ["PATH": "/custom/bin:/opt/homebrew/bin:/usr/bin"])
        #expect(env["PATH"] == "/custom/bin:/opt/homebrew/bin:/usr/bin:/usr/local/bin:/bin:/usr/sbin:/sbin")
    }

    @Test func buildsPathWhenNoneIsInherited() {
        #expect(OsttHelper.environment(inheriting: [:])["PATH"] == OsttHelper.requiredPath.joined(separator: ":"))
    }

    @Test func inheritsOtherVariables() {
        let env = OsttHelper.environment(inheriting: ["HOME": "/Users/someone", "XDG_CONFIG_HOME": "/tmp/cfg"])
        #expect(env["HOME"] == "/Users/someone")
        #expect(env["XDG_CONFIG_HOME"] == "/tmp/cfg")
    }
}

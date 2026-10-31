import Foundation
import Testing
@testable import JustTranscribeKit

final class CredentialsStoreTests {
    let root = FileManager.default.temporaryDirectory.appending(path: "jt-creds-\(UUID().uuidString)", directoryHint: .isDirectory)

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
    var paths: OsttPaths {
        OsttPaths(configDirectory: root.appending(path: "config/ostt"), dataDirectory: root.appending(path: "data/ostt"))
    }
    var store: CredentialsStore { CredentialsStore(paths: paths) }

    private func seed(_ content: String, mode: Int16 = 0o600) throws {
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        try Data(content.utf8).write(to: paths.credentialsFile)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: paths.credentialsFile.path())
    }

    private func content() throws -> String {
        try String(contentsOf: paths.credentialsFile, encoding: .utf8)
    }

    private func mode(_ url: URL) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: url.path())[.posixPermissions] as? Int)
    }

    @Test func createsPrivateFileAndDirectory() throws {
        try store.setKey(provider: "elevenlabs", key: "test-key-123")
        #expect(try content() == "elevenlabs = \"test-key-123\"\n")
        #expect(try mode(paths.credentialsFile) == 0o600)
        #expect(try mode(paths.dataDirectory) == 0o700)
    }

    @Test func replacingKeepsOtherLinesByteForByte() throws {
        let original = "# my keys\nopenai = \"sk-old\"  # work account\n\n[weird]\nunknown.dotted = 1\ngroq=\"gsk\"\r\n"
        try seed(original)
        try store.setKey(provider: "openai", key: "sk-new")
        #expect(try content() == original.replacingOccurrences(of: "openai = \"sk-old\"  # work account", with: "openai = \"sk-new\""))
    }

    @Test func appendsAfterLastLine() throws {
        try seed("# comment\nopenai = \"sk\"\n")
        try store.setKey(provider: "groq", key: "gsk")
        #expect(try content() == "# comment\nopenai = \"sk\"\ngroq = \"gsk\"\n")
    }

    @Test func appendsToFileWithoutTrailingNewline() throws {
        try seed("openai = \"sk\"")
        try store.setKey(provider: "groq", key: "gsk")
        #expect(try content() == "openai = \"sk\"\ngroq = \"gsk\"\n")
    }

    @Test func replacesQuotedKeyAndDropsDuplicates() throws {
        try seed("\"openai\" = 'sk-a'\nmistral = \"m\"\nopenai = \"sk-b\"\n")
        try store.setKey(provider: "openai", key: "sk-c")
        #expect(try content() == "openai = \"sk-c\"\nmistral = \"m\"\n")
    }

    @Test func escapesQuotesBackslashesAndControlCharacters() throws {
        let key = "a\"b\\c\td\u{1}e\u{7F}é"
        try store.setKey(provider: "deepgram", key: key)
        #expect(try content() == "deepgram = \"a\\\"b\\\\c\\td\\u0001e\\u007Fé\"\n")
        #expect(try store.maskedKey(provider: "deepgram") == "••••\u{1}e\u{7F}é")
    }

    @Test func readsEscapedAndLiteralValues() throws {
        try seed("openai = \"sk-\\u0041\\\"12345\"\ngroq = 'C:\\raw\\path'\n")
        // Decodes to `sk-A"12345`.
        #expect(try store.maskedKey(provider: "openai") == "••••2345")
        #expect(try store.maskedKey(provider: "groq") == "••••path")
    }

    @Test func rejectsKeysThatWouldBreakTheFormat() throws {
        try seed("openai = \"sk\"\n")
        #expect(throws: CredentialsStore.Failure.multilineKey) { try store.setKey(provider: "openai", key: "a\nb") }
        #expect(throws: CredentialsStore.Failure.multilineKey) { try store.setKey(provider: "openai", key: "a\rb") }
        #expect(throws: CredentialsStore.Failure.emptyKey) { try store.setKey(provider: "openai", key: "") }
        #expect(throws: CredentialsStore.Failure.invalidProviderID("open ai")) {
            try store.setKey(provider: "open ai", key: "k")
        }
        #expect(try content() == "openai = \"sk\"\n")
    }

    @Test func removeDeletesOnlyThatProvider() throws {
        try seed("# keep\nopenai = \"sk\"\ngroq = \"gsk\" # note\n")
        try store.removeKey(provider: "openai")
        #expect(try content() == "# keep\ngroq = \"gsk\" # note\n")
        #expect(try store.hasKey(provider: "openai") == false)
        #expect(try store.hasKey(provider: "groq"))
    }

    @Test func removingAbsentKeyLeavesFileAlone() throws {
        try seed("groq = \"gsk\"", mode: 0o644)
        try store.removeKey(provider: "openai")
        #expect(try content() == "groq = \"gsk\"")
        #expect(try mode(paths.credentialsFile) == 0o644)
        try CredentialsStore(paths: OsttPaths(configDirectory: root, dataDirectory: root.appending(path: "none")))
            .removeKey(provider: "openai")
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "none").path()))
    }

    @Test func rewriteRestrictsReadableFile() throws {
        try seed("groq = \"gsk\"\n", mode: 0o644)
        try store.setKey(provider: "openai", key: "sk")
        #expect(try mode(paths.credentialsFile) == 0o600)
    }

    @Test func leavesNoTemporaryFiles() throws {
        for index in 0..<5 {
            try store.setKey(provider: "openai", key: "sk-\(index)")
            try store.setKey(provider: "groq", key: "gsk-\(index)")
            try store.removeKey(provider: "groq")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: paths.dataDirectory.path()) == ["credentials"])
    }

    @Test func listsProvidersAndMasksKeys() throws {
        #expect(try store.configuredProviders() == [])
        #expect(try store.maskedKey(provider: "openai") == nil)
        try seed("openai = \"sk-proj-abcdWXYZ\"\nmistral = \"short\"\n# groq = \"commented\"\n")
        #expect(try store.configuredProviders() == ["openai", "mistral"])
        #expect(try store.maskedKey(provider: "openai") == "••••WXYZ")
        #expect(try store.maskedKey(provider: "mistral") == "••••")
        #expect(try store.hasKey(provider: "groq") == false)
    }

    @Test func refusesToRewriteNonUTF8File() throws {
        try FileManager.default.createDirectory(at: paths.dataDirectory, withIntermediateDirectories: true)
        let bytes = Data([0x6F, 0x3D, 0xFF, 0xFE, 0x0A])
        try bytes.write(to: paths.credentialsFile)
        #expect(throws: CredentialsStore.Failure.unreadableFile) { try store.setKey(provider: "openai", key: "sk") }
        #expect(try Data(contentsOf: paths.credentialsFile) == bytes)
    }

    @Test(arguments: ["openai = \"\"\"sk-multi\"\"\"", "openai.org = \"x\"", "\"openai\" = 42"])
    func refusesToEditAroundAnEntryItCannotRead(line: String) throws {
        let original = "groq = \"gsk\"\n\(line)\n"
        try seed(original)
        #expect(throws: CredentialsStore.Failure.unrecognizedEntry("openai")) { try store.setKey(provider: "openai", key: "sk") }
        #expect(throws: CredentialsStore.Failure.unrecognizedEntry("openai")) { try store.removeKey(provider: "openai") }
        try store.setKey(provider: "mistral", key: "m")
        #expect(try content() == original + "mistral = \"m\"\n")
    }
}

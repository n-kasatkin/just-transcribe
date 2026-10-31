import Foundation

/// ostt's API key file (`src/config/secrets.rs`): flat TOML, one `provider_id = "key"` line per
/// provider. Edits touch only the given provider's line and keep every other byte as it was.
/// Key material leaves this type only as `maskedKey(provider:)`.
public struct CredentialsStore: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// Not a TOML bare key, the only form ostt itself writes.
        case invalidProviderID(String)
        case emptyKey
        /// A newline would break the one-line-per-provider format.
        case multilineKey
        /// The file is not UTF-8 text, so it is left untouched.
        case unreadableFile
    }

    public let paths: OsttPaths

    public init(paths: OsttPaths) {
        self.paths = paths
    }

    /// Provider ids that have a key, in file order.
    public func configuredProviders() throws -> [String] {
        try lines().compactMap { Self.entry($0)?.provider }
    }

    public func hasKey(provider: String) throws -> Bool {
        try key(provider: provider) != nil
    }

    /// The saved key as `••••` plus its last four characters (only `••••` for keys under 8).
    public func maskedKey(provider: String) throws -> String? {
        guard let key = try key(provider: provider) else { return nil }
        return key.count >= 8 ? "••••" + key.suffix(4) : "••••"
    }

    /// Replaces the provider's line, or appends one when it has none.
    public func setKey(provider: String, key: String) throws {
        try Self.validate(provider: provider)
        guard !key.isEmpty else { throw Failure.emptyKey }
        guard !key.contains(where: \.isNewline) else { throw Failure.multilineKey }

        let newLine = Array("\(provider) = \(Self.basicString(key))".utf8)
        var replaced = false
        // Later duplicates are dropped: TOML rejects a repeated key, and ostt then reads no keys at all.
        var lines = try lines().compactMap { line -> [UInt8]? in
            guard Self.entry(line)?.provider == provider else { return line }
            defer { replaced = true }
            return replaced ? nil : newLine
        }
        if !replaced {
            if lines.last == [] {
                lines.insert(newLine, at: lines.count - 1)
            } else {
                lines += [newLine, []]
            }
        }
        try write(lines)
    }

    /// Deletes the provider's line; does nothing when it has none.
    public func removeKey(provider: String) throws {
        try Self.validate(provider: provider)
        let lines = try lines()
        let kept = lines.filter { Self.entry($0)?.provider != provider }
        if kept.count != lines.count {
            try write(kept)
        }
    }

    private func key(provider: String) throws -> String? {
        try lines().lazy.compactMap(Self.entry).first { $0.provider == provider }?.key
    }

    // MARK: File

    /// The file split at `\n`, bytes untouched; a trailing newline leaves an empty last line.
    private func lines() throws -> [[UInt8]] {
        let data: Data
        do {
            data = try Data(contentsOf: paths.credentialsFile)
        } catch CocoaError.fileReadNoSuchFile {
            return []
        }
        guard String(data: data, encoding: .utf8) != nil else { throw Failure.unreadableFile }
        guard !data.isEmpty else { return [] }
        return data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map(Array.init)
    }

    /// Writes a new 0600 file beside the old one and renames it over, as ostt's `write_private` does,
    /// so no reader ever sees a partial file or a moment of wider permissions.
    private func write(_ lines: [[UInt8]]) throws {
        let directory = paths.dataDirectory
        if !FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
            )
        }
        let bytes = Array(lines.joined(separator: [UInt8(ascii: "\n")]))
        let target = paths.credentialsFile.path(percentEncoded: false)
        let temp = directory.appending(path: ".credentials-\(UUID().uuidString).tmp").path(percentEncoded: false)

        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        var isOpen = true
        do {
            // The umask may have narrowed the mode further; ostt expects exactly 0600.
            try Self.check(fchmod(fd, 0o600))
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
                try Self.check(written < 0 ? -1 : 0)
                offset += written
            }
            try Self.check(fsync(fd))
            isOpen = false
            try Self.check(close(fd))
            try Self.check(rename(temp, target))
        } catch {
            if isOpen { close(fd) }
            unlink(temp)
            throw error
        }
    }

    private static func check(_ status: Int32) throws {
        if status != 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
    }

    // MARK: TOML

    private static func validate(provider: String) throws {
        guard !provider.isEmpty, provider.unicodeScalars.allSatisfy(isBareKeyScalar) else {
            throw Failure.invalidProviderID(provider)
        }
    }

    private static func isBareKeyScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
        default: false
        }
    }

    /// A TOML basic string: `"` and `\` escaped, control characters as `\uXXXX`.
    static func basicString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The `provider = "key"` pair of one line, or nil for blanks, comments and anything else.
    /// Reads bare, basic and literal keys and basic and literal string values, as ostt's TOML parser does.
    static func entry(_ line: [UInt8]) -> (provider: String, key: String)? {
        var scanner = LineScanner(String(decoding: line, as: UTF8.self))
        scanner.skipSpaces()
        guard let provider = scanner.key() else { return nil }
        scanner.skipSpaces()
        guard scanner.take("=") else { return nil }
        scanner.skipSpaces()
        guard let key = scanner.string() else { return nil }
        scanner.skipSpaces()
        guard scanner.isAtEnd || scanner.peek == "#" else { return nil }
        return (provider, key)
    }

    private struct LineScanner {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ line: String) {
            scalars = Array(line.unicodeScalars)
        }

        var isAtEnd: Bool { index == scalars.count }
        var peek: Unicode.Scalar? { isAtEnd ? nil : scalars[index] }

        mutating func skipSpaces() {
            while let scalar = peek, scalar == " " || scalar == "\t" || scalar == "\r" { index += 1 }
        }

        mutating func take(_ scalar: Unicode.Scalar) -> Bool {
            guard peek == scalar else { return false }
            index += 1
            return true
        }

        mutating func key() -> String? {
            if peek == "\"" || peek == "'" { return string() }
            var key = ""
            while let scalar = peek, CredentialsStore.isBareKeyScalar(scalar) {
                key.unicodeScalars.append(scalar)
                index += 1
            }
            return key.isEmpty ? nil : key
        }

        mutating func string() -> String? {
            if take("'") { return literal() }
            guard take("\"") else { return nil }
            var value = ""
            while let scalar = peek {
                index += 1
                switch scalar {
                case "\"": return value
                case "\\":
                    guard let escaped = escape() else { return nil }
                    value.unicodeScalars.append(escaped)
                default: value.unicodeScalars.append(scalar)
                }
            }
            return nil
        }

        private mutating func literal() -> String? {
            var value = ""
            while let scalar = peek {
                index += 1
                if scalar == "'" { return value }
                value.unicodeScalars.append(scalar)
            }
            return nil
        }

        private mutating func escape() -> Unicode.Scalar? {
            guard let scalar = peek else { return nil }
            index += 1
            switch scalar {
            case "b": return "\u{08}"
            case "t": return "\t"
            case "n": return "\n"
            case "f": return "\u{0C}"
            case "r": return "\r"
            case "\"", "\\": return scalar
            case "u": return hex(digits: 4)
            case "U": return hex(digits: 8)
            default: return nil
            }
        }

        private mutating func hex(digits: Int) -> Unicode.Scalar? {
            guard index + digits <= scalars.count else { return nil }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars[index..<index + digits])
            index += digits
            return UInt32(text, radix: 16).flatMap(Unicode.Scalar.init)
        }
    }
}

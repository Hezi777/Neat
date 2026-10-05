import Foundation
import NeatCore

/// Where API credentials come from, in one place.
///
/// Resolution order, first hit wins: the process environment, then `~/Neat/.env`,
/// then the Keychain. The environment comes first so a terminal run of
/// `neat-cli` can override whatever the app has stored; the Keychain is last
/// because it only ever held the one Anthropic key.
///
/// Values are never logged. Nothing in this type prints a secret, not even at
/// debug level, and no caller should either.
public struct SecretsStore: Sendable {
    public enum Key: String, Sendable, CaseIterable {
        case groq = "GROQ_API_KEY"
        case notionToken = "NOTION_TOKEN"
        case notionResourcesDB = "NOTION_RESOURCES_DB_ID"
        case anthropic = "ANTHROPIC_API_KEY"
    }

    let environment: [String: String]
    let envFile: URL
    let keychain: KeychainStore

    public init(
        paths: NeatPaths = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        keychain: KeychainStore = KeychainStore()
    ) {
        self.environment = environment
        self.envFile = paths.root.appending(path: ".env")
        self.keychain = keychain
    }

    public func value(for key: Key) -> String? {
        if let fromEnv = nonEmpty(environment[key.rawValue]) { return fromEnv }
        // Re-read each time rather than caching: the file is tiny, and a key
        // added while the app is running should work without a relaunch.
        if let fromFile = nonEmpty(Self.parse(fileText())[key.rawValue]) { return fromFile }
        if key == .anthropic { return keychain.load() }
        return nil
    }

    public func has(_ key: Key) -> Bool { value(for: key) != nil }

    func fileText() -> String {
        (try? String(contentsOf: envFile, encoding: .utf8)) ?? ""
    }

    func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }

    /// A deliberately forgiving `KEY=VALUE` parser. This file is hand-edited, so
    /// it tolerates CRLF, blank lines, `#` comments, `export` prefixes, spaces
    /// around the `=`, and surrounding quotes. A value may contain `=`, so only
    /// the first one splits. Anything it cannot make sense of is ignored rather
    /// than raised — a malformed line must not stop the app from starting.
    static func parse(_ text: String) -> [String: String] {
        var out: [String: String] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") {
                line = String(line.dropFirst("export ".count)).trimmingCharacters(in: .whitespaces)
            }

            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty else { continue }

            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            // Only a matched pair of quotes is stripped; a lone quote is part of
            // the value. `#` is never treated as a comment inside a value —
            // tokens contain it.
            if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
                value = String(value.dropFirst().dropLast())
            }

            out[key] = value
        }

        return out
    }
}

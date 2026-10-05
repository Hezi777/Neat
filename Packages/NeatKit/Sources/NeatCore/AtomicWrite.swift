import Foundation

extension Date {
    /// Whole seconds, matching what ISO-8601 can represent.
    ///
    /// `Date` carries sub-second precision that the `.iso8601` strategy drops on
    /// write, so an untruncated timestamp would not survive a round trip — and
    /// every load/save cycle would rewrite `item.json` with a spurious diff.
    /// Truncating on the way in makes the on-disk form lossless.
    public var neatTruncated: Date {
        Date(timeIntervalSince1970: timeIntervalSince1970.rounded(.down))
    }

    /// Now, at the precision Neat actually stores.
    public static var neatNow: Date { Date().neatTruncated }
}

/// JSON coder used for every file Neat writes, so `item.json` and `ledger.json`
/// stay readable by hand and diffable in git.
public enum NeatJSON {
    public static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    public static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// Writes via a temp file plus rename, so a crash mid-write can never leave a
/// truncated `ledger.json` behind.
public func atomicWrite(_ data: Data, to url: URL) throws {
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let temp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    try data.write(to: temp, options: .atomic)

    do {
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    } catch {
        try? FileManager.default.removeItem(at: temp)
        throw error
    }
}

public func atomicWriteJSON(_ value: some Encodable, to url: URL) throws {
    try atomicWrite(NeatJSON.encoder.encode(value), to: url)
}

public func atomicWrite(_ string: String, to url: URL) throws {
    try atomicWrite(Data(string.utf8), to: url)
}

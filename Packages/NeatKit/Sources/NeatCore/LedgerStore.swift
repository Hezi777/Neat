import Foundation

/// Reads and writes `~/Neat/ledger.json`.
///
/// A missing or unreadable ledger is an empty ledger, never a crash — the
/// folders on disk are the real record and the ledger is recoverable from them.
public struct LedgerStore: Sendable {
    public let paths: NeatPaths

    public init(paths: NeatPaths = .default) {
        self.paths = paths
    }

    public func load() -> Ledger {
        guard let data = try? Data(contentsOf: paths.ledger) else { return Ledger() }
        do {
            return try NeatJSON.decoder.decode(Ledger.self, from: data)
        } catch {
            Log.core.error("ledger.json unreadable, starting empty: \(error.localizedDescription, privacy: .public)")
            return Ledger()
        }
    }

    public func save(_ ledger: Ledger) throws {
        try atomicWriteJSON(ledger, to: paths.ledger)
    }

    /// Read, mutate, write. The only supported way to change the ledger, so the
    /// write stays atomic and nothing half-updates it.
    @discardableResult
    public func update<T>(_ body: (inout Ledger) throws -> T) throws -> T {
        var ledger = load()
        let result = try body(&ledger)
        try save(ledger)
        return result
    }
}

/// Reads what is actually on disk under `items/`.
///
/// The folder is the authority: when it disagrees with the ledger, this wins.
public struct ItemStore: Sendable {
    public let paths: NeatPaths

    public init(paths: NeatPaths = .default) {
        self.paths = paths
    }

    public func exists(_ id: CanonicalID) -> Bool {
        FileManager.default.fileExists(atPath: paths.itemJSON(id).path())
    }

    public func load(_ id: CanonicalID) -> Item? {
        guard let data = try? Data(contentsOf: paths.itemJSON(id)) else { return nil }
        do {
            return try NeatJSON.decoder.decode(Item.self, from: data)
        } catch {
            Log.core.error("item.json unreadable for \(id.folderName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    public func save(_ item: Item) throws {
        try atomicWriteJSON(item, to: paths.itemJSON(item.id))
    }
}

import Foundation

/// Why an item is or is not worth touching again.
///
/// Without this, every deleted video is retried on every run — and a good
/// fraction of a months-old saved list is dead.
public enum LedgerStatus: String, Codable, Sendable {
    case queued
    case done
    /// Fetch failed twice. Do not try again.
    case dead
    /// Marked as junk by hand. Never returns.
    case skipped
}

public struct LedgerEntry: Codable, Sendable, Equatable {
    public var status: LedgerStatus
    public var lastSeen: Date?
    public var attempts: Int

    public init(status: LedgerStatus, lastSeen: Date? = nil, attempts: Int = 0) {
        self.status = status
        self.lastSeen = lastSeen
        self.attempts = attempts
    }
}

/// `~/Neat/ledger.json` — one entry per canonical ID ever seen.
///
/// The folder on disk is the authority. If `item.json` says a stage is done,
/// believe it over the ledger.
public struct Ledger: Codable, Sendable {
    public var entries: [String: LedgerEntry]

    public init(entries: [String: LedgerEntry] = [:]) {
        self.entries = entries
    }

    public subscript(id: CanonicalID) -> LedgerEntry? {
        get { entries[id.folderName] }
        set { entries[id.folderName] = newValue }
    }

    public func contains(_ id: CanonicalID) -> Bool {
        entries[id.folderName] != nil
    }
}

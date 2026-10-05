import Foundation

/// What a pasted link turned out to be, once the canonical ID is known and the
/// disk and ledger have been consulted.
public enum Disposition: Sendable, Equatable {
    /// Never seen. This one gets queued.
    case new
    /// Already on disk. Nothing to download.
    case alreadyHave
    /// The ledger says fetching it failed for good.
    case unavailable
    /// Marked as junk by hand. Never comes back.
    case skipped
    /// Not a link we can key — junk in the pasted text, or an unsupported URL.
    case invalid(String)
}

/// One line of the pasted text, after classification. Order is paste order, so
/// `savedRank` survives.
public struct IntakeEntry: Sendable, Equatable {
    public let raw: String
    public let id: CanonicalID?
    public let disposition: Disposition

    public init(raw: String, id: CanonicalID?, disposition: Disposition) {
        self.raw = raw
        self.id = id
        self.disposition = disposition
    }
}

/// The counts behind the one line shown before any work starts.
///
/// This single line is what makes the app feel like a real tool, so it is
/// computed up front rather than discovered as the queue drains.
public struct PasteSummary: Sendable, Equatable {
    public var new = 0
    public var alreadyHave = 0
    public var unavailable = 0
    public var skipped = 0
    public var invalid = 0

    public init() {}

    public init(entries: [IntakeEntry]) {
        for entry in entries {
            switch entry.disposition {
            case .new: new += 1
            case .alreadyHave: alreadyHave += 1
            case .unavailable: unavailable += 1
            case .skipped: skipped += 1
            case .invalid: invalid += 1
            }
        }
    }

    public var total: Int { new + alreadyHave + unavailable + skipped + invalid }

    /// `42 new, 58 already have, 6 unavailable`
    ///
    /// The three headline counts are always shown, even at zero, so the shape of
    /// the line never changes. Skipped and invalid are appended only when they
    /// actually happened — silently dropping junk from a paste would be a lie.
    public var line: String {
        var parts = [
            "\(new) new",
            "\(alreadyHave) already have",
            "\(unavailable) unavailable",
        ]
        if skipped > 0 { parts.append("\(skipped) skipped") }
        if invalid > 0 { parts.append("\(invalid) could not import") }
        return parts.joined(separator: ", ")
    }
}

/// The result of parsing and classifying a paste.
public struct IntakeResult: Sendable, Equatable {
    public let entries: [IntakeEntry]
    public let summary: PasteSummary

    public init(entries: [IntakeEntry]) {
        self.entries = entries
        self.summary = PasteSummary(entries: entries)
    }

    /// The items to actually queue, in paste order, with `savedRank` assigned.
    public var queued: [CanonicalID] {
        entries.compactMap { $0.disposition == .new ? $0.id : nil }
    }
}

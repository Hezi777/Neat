import Foundation
import NeatAdapters
import NeatCore

/// Turns pasted text into a classified batch, before any work starts.
///
/// Order of authority when deciding what a link is:
///   1. a folder on disk wins over everything
///   2. then the ledger's deliberate markers (`dead`, `skipped`)
///   3. otherwise it is new
///
/// Note the deliberate asymmetry: a ledger entry saying `done` with no folder on
/// disk is treated as **new**, not as already-had. Deleting a folder is how you
/// ask for something to be redone, and the ledger must not veto that.
public struct PasteIntake: Sendable {
    let adapters: [any SourceAdapter]
    let items: ItemStore
    let ledgerStore: LedgerStore
    /// How many short links to resolve at once. Enough to keep a big paste
    /// quick, small enough not to look like an attack.
    let concurrency: Int
    let listCollection: @Sendable (URL) async throws -> [URL]

    public init(
        adapters: [any SourceAdapter] = [TikTokAdapter(), ThreadsAdapter()],
        items: ItemStore = ItemStore(),
        ledgerStore: LedgerStore = LedgerStore(),
        concurrency: Int = 6,
        listCollection: @escaping @Sendable (URL) async throws -> [URL] = {
            try await TikTokCollection().posts(in: $0)
        }
    ) {
        self.adapters = adapters
        self.items = items
        self.ledgerStore = ledgerStore
        self.concurrency = concurrency
        self.listCollection = listCollection
    }

    public func intake(text: String) async -> IntakeResult {
        let urls = PasteParser.extractURLs(from: text)
        guard !urls.isEmpty else { return IntakeResult(entries: []) }

        let resolved = await canonicalize(urls)
        let ledger = ledgerStore.load()

        var entries: [IntakeEntry] = []
        var seen = Set<CanonicalID>()

        for entry in resolved {
            guard let id = entry.id else {
                entries.append(entry)
                continue
            }
            // The same post pasted twice, or via both a short and a long link,
            // is one item. This is the dedup the folder naming guarantees.
            guard seen.insert(id).inserted else { continue }

            entries.append(IntakeEntry(raw: entry.raw, id: id,
                                       disposition: classify(id, ledger: ledger)))
        }

        return IntakeResult(entries: entries)
    }

    func classify(_ id: CanonicalID, ledger: Ledger) -> Disposition {
        if items.exists(id) { return .alreadyHave }
        switch ledger[id]?.status {
        case .dead: return .unavailable
        case .skipped: return .skipped
        default: return .new
        }
    }

    /// Resolves every URL to an ID, in parallel but bounded, preserving paste order.
    func canonicalize(_ urls: [URL]) async -> [IntakeEntry] {
        await withTaskGroup(of: (Int, [IntakeEntry]).self) { group in
            var results = [[IntakeEntry]](repeating: [], count: urls.count)
            var next = 0

            func submit(_ i: Int) {
                let url = urls[i]
                group.addTask {
                    guard let adapter = adapters.first(where: { $0.canHandle(url) }) else {
                        return (i, [IntakeEntry(raw: url.absoluteString, id: nil,
                                               disposition: .invalid("Not a supported link."))])
                    }
                    do {
                        let resolved = try await adapter.resolvedURL(for: url)
                        let posts = TikTokURL.isCollection(resolved)
                            ? try await listCollection(resolved) : [resolved]
                        var entries: [IntakeEntry] = []
                        for post in posts {
                            let id = try await adapter.canonicalID(for: post)
                            entries.append(IntakeEntry(raw: post.absoluteString, id: id, disposition: .new))
                        }
                        return (i, entries)
                    } catch {
                        Log.pipeline.notice(
                            "could not key \(url.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
                        let message = error is CollectionError ? error.localizedDescription
                            : "Could not read this link. Check the link and your connection, then try again."
                        return (i, [IntakeEntry(raw: url.absoluteString, id: nil,
                                               disposition: .invalid(message))])
                    }
                }
            }

            while next < urls.count && next < concurrency { submit(next); next += 1 }

            for await (i, entries) in group {
                results[i] = entries
                if next < urls.count { submit(next); next += 1 }
            }

            return results.flatMap { $0 }
        }
    }
}

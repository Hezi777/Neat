import Foundation
import NeatCore

/// What a row is doing right now.
public enum ItemState: Sendable, Equatable {
    case queued
    case fetching
    case listening
    case reading
    case done
    case dead(String)
    case skipped
}

public struct LibraryEvent: Sendable {
    public let id: CanonicalID
    public let state: ItemState
}

/// Owns `~/Neat/`: creates folders, runs stages, keeps the ledger honest.
///
/// Resume is not a special mode. `run()` simply processes everything that still
/// needs work, so a forced quit is indistinguishable from never having started.
public struct Library: Sendable {
    public let paths: NeatPaths
    let items: ItemStore
    let ledgerStore: LedgerStore
    let stages: [any Stage]

    public init(
        paths: NeatPaths = .default,
        stages: [any Stage] = [FetchStage()]
    ) {
        self.paths = paths
        self.items = ItemStore(paths: paths)
        self.ledgerStore = LedgerStore(paths: paths)
        self.stages = stages
    }

    /// Writes a folder and `item.json` for everything new, and marks it queued.
    ///
    /// Existing folders are left completely alone — this never overwrites an
    /// item that is already on disk.
    @discardableResult
    public func enqueue(_ result: IntakeResult) throws -> [CanonicalID] {
        var queued: [CanonicalID] = []

        try ledgerStore.update { ledger in
            for (rank, entry) in result.entries.enumerated() {
                guard let id = entry.id else { continue }

                switch entry.disposition {
                case .new:
                    if !items.exists(id) {
                        try? items.save(Item(id: id, url: entry.raw, platform: id.platform, savedRank: rank))
                    }
                    ledger[id] = LedgerEntry(status: .queued, lastSeen: .neatNow,
                                             attempts: ledger[id]?.attempts ?? 0)
                    queued.append(id)

                case .alreadyHave:
                    ledger[id]?.lastSeen = .neatNow
                case .unavailable, .skipped, .invalid:
                    break
                }
            }
        }

        return queued
    }

    /// Every item on disk that still has work left at the current stage versions.
    public func pending() -> [Item] {
        allItems().filter { item in needsWork(item) }
    }

    public func needsWork(_ item: Item) -> Bool {
        stages.contains { $0.needsRun(item) }
    }

    public func allItems() -> [Item] {
        let dirs = (try? FileManager.default.contentsOfDirectory(
            at: paths.items, includingPropertiesForKeys: nil)) ?? []

        return dirs
            .compactMap { CanonicalID(folderName: $0.lastPathComponent) }
            .compactMap { items.load($0) }
            .sorted { ($0.savedRank ?? .max) < ($1.savedRank ?? .max) }
    }

    /// Runs every pending item's outstanding stages, in order.
    public func run(onEvent: @Sendable (LibraryEvent) -> Void = { _ in }) async {
        for item in pending() {
            await process(item, onEvent: onEvent)
        }
    }

    public func process(_ item: Item, onEvent: @Sendable (LibraryEvent) -> Void = { _ in }) async {
        var current = item

        for stage in stages {
            guard stage.needsRun(current) else { continue }
            onEvent(LibraryEvent(id: current.id, state: stage.runningState))

            do {
                current = try await stage.run(current, paths: paths)
                try items.save(current)
            } catch {
                await recordFailure(current, stage: stage, error: error, onEvent: onEvent)
                return
            }
        }

        try? ledgerStore.update { $0[current.id] = LedgerEntry(status: .done, lastSeen: .neatNow) }
        onEvent(LibraryEvent(id: current.id, state: .done))
    }

    /// Two attempts, then dead. The reason is kept on the item so a dead row can
    /// say why rather than just failing silently.
    func recordFailure(
        _ item: Item, stage: any Stage, error: any Error,
        onEvent: @Sendable (LibraryEvent) -> Void
    ) async {
        let reason = describe(error)
        Log.pipeline.error("\(stage.name, privacy: .public) failed for \(item.id.folderName, privacy: .public): \(reason, privacy: .public)")

        var item = item
        stage.recordError(&item, reason: reason)
        try? items.save(item)

        // A rate limit is the service being busy, not the item being bad. An
        // afternoon of them would otherwise mark a whole collection dead two
        // attempts at a time, and nothing about those items would be wrong.
        // The reason is still written to the item so the row can say why it
        // stalled; only the attempt is withheld.
        if case StageError.rateLimited = error {
            try? ledgerStore.update { ledger in
                ledger[item.id] = LedgerEntry(
                    status: .queued, lastSeen: .neatNow, attempts: ledger[item.id]?.attempts ?? 0)
            }
            onEvent(LibraryEvent(id: item.id, state: .queued))
            return
        }

        let attempts = (try? ledgerStore.update { ledger -> Int in
            let next = (ledger[item.id]?.attempts ?? 0) + 1
            let status: LedgerStatus = next >= FetchStage.maxAttempts ? .dead : .queued
            ledger[item.id] = LedgerEntry(status: status, lastSeen: .neatNow, attempts: next)
            return next
        }) ?? 1

        onEvent(LibraryEvent(
            id: item.id,
            state: attempts >= FetchStage.maxAttempts ? .dead(reason) : .queued))
    }

    // MARK: - Resources

    /// What the extract stage found for one item. Empty when it has not run, or
    /// genuinely found nothing — the caller cannot tell those apart from here,
    /// and does not need to: `item.stages.extract` says which it was.
    public func resources(for id: CanonicalID) -> [Resource] {
        guard let data = try? Data(contentsOf: paths.resources(id)) else { return [] }
        do {
            return try NeatJSON.decoder.decode(ResourcesFile.self, from: data).resources
        } catch {
            Log.pipeline.error("resources.json unreadable for \(id.folderName, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Every resource in the library, paired with the item it came from, in the
    /// same order `allItems()` uses.
    public func allResources() -> [(item: Item, resource: Resource)] {
        allItems().flatMap { item in
            resources(for: item.id).map { (item: item, resource: $0) }
        }
    }

    /// Records that a resource has (or has not) been pushed to Notion.
    ///
    /// Rewrites the whole file atomically rather than patching it, and does
    /// nothing at all if the id is not in it — there is no row to remember.
    public func setPushed(_ resourceID: String, for item: CanonicalID, to pushed: Bool) {
        var all = resources(for: item)
        guard let index = all.firstIndex(where: { $0.id == resourceID }) else {
            Log.pipeline.error("no resource \(resourceID, privacy: .public) in \(item.folderName, privacy: .public)")
            return
        }
        guard all[index].pushedToNotion != pushed else { return }

        all[index].pushedToNotion = pushed
        do {
            try atomicWriteJSON(
                ResourcesFile(v: StageVersions.extract, resources: all), to: paths.resources(item))
        } catch {
            Log.pipeline.error("could not save resources.json for \(item.folderName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    func describe(_ error: any Error) -> String {
        switch error {
        case let ProcessError.failed(command, status, stderr):
            let tail = stderr.split(separator: "\n").last.map(String.init) ?? ""
            return "\(command) exited \(status): \(tail)"
        case let StageError.toolMissing(tool): return "\(tool) is not installed"
        case let StageError.fetchFailed(why): return why
        case let StageError.rateLimited(_, detail): return "rate limited, will retry: \(detail)"
        default: return error.localizedDescription
        }
    }
}

extension Stage {
    /// Whether this stage still has to run for the given item.
    func needsRun(_ item: Item) -> Bool {
        state(of: item).needsRun(currentVersion: version)
    }

    func state(of item: Item) -> StageState {
        switch name {
        case "fetch": item.stages.fetch
        case "transcribe": item.stages.transcribe
        case "extract": item.stages.extract
        default: item.stages.onscreen
        }
    }

    func recordError(_ item: inout Item, reason: String) {
        switch name {
        case "fetch": item.stages.fetch.error = reason
        case "transcribe": item.stages.transcribe.error = reason
        case "extract": item.stages.extract.error = reason
        default: item.stages.onscreen.error = reason
        }
    }

    /// Extract reuses `.reading` rather than gaining a state of its own: it is
    /// reading the same material the onscreen stage just read, and a new case
    /// would be a row state the UI has no distinct way to show.
    var runningState: ItemState {
        switch name {
        case "fetch": .fetching
        case "transcribe": .listening
        default: .reading
        }
    }
}

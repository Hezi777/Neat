import AppKit
import Foundation
import NeatCore
import NeatPipeline
import Observation

/// A source in the sidebar.
///
/// TikTok and Threads deliberately do not share a list — they are different
/// kinds of material and mixing them would make the queue unreadable. New
/// services slot in here without touching anything else.
public struct Source: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let platform: Platform?
    public let isAvailable: Bool
    public let icon: NeatIcon

    public static let tiktok = Source(id: "tiktok", name: "TikTok", platform: .tiktok, isAvailable: true, icon: .srcTiktok)
    public static let threads = Source(id: "threads", name: "Threads", platform: .threads, isAvailable: true, icon: .srcThreads)

    /// Named now so the sidebar shows the intended shape of the app; none of
    /// them are implemented, and each is greyed out until its adapter exists.
    public static let planned: [Source] = [
        Source(id: "instagram", name: "Instagram", platform: nil, isAvailable: false, icon: .srcInstagram),
        Source(id: "youtube", name: "YouTube", platform: nil, isAvailable: false, icon: .srcYoutube),
        Source(id: "reddit", name: "Reddit", platform: nil, isAvailable: false, icon: .srcReddit),
    ]

    /// Not a platform — the cross-cutting view of everything extracted.
    public static let resources = Source(id: "resources", name: "Resources", platform: nil,
                                         isAvailable: true, icon: .dropWell)

    public static let all: [Source] = [.tiktok, .threads] + planned

    public var isResources: Bool { id == Source.resources.id }
}

/// One row in the queue.
public struct QueueRow: Identifiable, Sendable {
    public let id: CanonicalID
    public var state: ItemState
    public var title: String
    public var subtitle: String
    public var folder: URL

    public var isFinished: Bool {
        if case .done = state { return true }
        if case .dead = state { return true }
        return false
    }
}

@MainActor
@Observable
public final class AppModel {
    public private(set) var rows: [QueueRow] = []
    public private(set) var summary: PasteSummary?
    public private(set) var isWorking = false
    public private(set) var isAccepting = false
    public private(set) var intakeErrors: [String] = []
    public private(set) var preflight: PreflightResult
    public var selectedSource: Source = .tiktok
    public var showingKeySheet = false
    public var selection: Set<CanonicalID> = []
    public private(set) var isExtracting: Set<CanonicalID> = []
    public private(set) var pushState: [String: PushState] = [:]
    public var duplicatePrompt: DuplicatePrompt?
    let secrets: SecretsStore

    let paths: NeatPaths
    let intake: PasteIntake
    let library: Library
    let ledgerStore: LedgerStore
    let keychain = KeychainStore()

    public init(paths: NeatPaths = .default) {
        self.paths = paths
        self.ledgerStore = LedgerStore(paths: paths)
        self.intake = PasteIntake(items: ItemStore(paths: paths), ledgerStore: LedgerStore(paths: paths))
        // Scoped to `paths`, not the default root: a model pointed at another
        // library must read that library's `.env`, or it silently picks up
        // ~/Neat's keys while writing somewhere else entirely.
        let secrets = SecretsStore(paths: paths)
        self.secrets = secrets
        self.library = Library(
            paths: paths,
            stages: [
                FetchStage(), TranscribeStage(),
                OnscreenStage(secrets: secrets), ExtractStage(secrets: secrets),
            ])
        self.preflight = ToolPreflight().check()
        reloadFromDisk()
    }

    /// True for a key anywhere `SecretsStore` looks, not just the Keychain —
    /// the sheet still writes to the Keychain only.
    public var hasAPIKey: Bool { secrets.has(.anthropic) }

    public func saveAPIKey(_ key: String) {
        keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func recheckTools() { preflight = ToolPreflight().check() }

    // MARK: - resources

    public var canExtract: Bool { secrets.has(.groq) }

    public var canPushToNotion: Bool {
        secrets.has(.notionToken) && secrets.has(.notionResourcesDB)
    }

    public func resources(for id: CanonicalID) -> [Resource] { library.resources(for: id) }

    /// Cached by `reloadFromDisk()`. This used to be computed from
    /// `library.allResources()` on every access, which enumerates
    /// `~/Neat/items/` and JSON-decodes every item's `resources.json` — reading
    /// it from the sidebar and `AllResourcesScreen` during layout (e.g. the
    /// sidebar show/hide animation) meant a full disk sweep per frame.
    public private(set) var everyResource: [(item: Item, resource: Resource)] = []

    /// The inspector shows one item. With a multiple selection there is no
    /// single item to inspect, so it stays hidden rather than picking one.
    public var inspectedRow: QueueRow? {
        guard selection.count == 1, let id = selection.first else { return nil }
        return rows.first { $0.id == id }
    }

    public var selectedRows: [QueueRow] {
        rows.filter { selection.contains($0.id) }
    }

    /// Removes every selected item at once — Delete on a multiple selection
    /// should not remove only the first.
    public func remove(_ ids: some Collection<CanonicalID>) {
        for id in ids { remove(id) }
        selection.subtract(ids)
    }

    public func revealInFinder(_ ids: some Collection<CanonicalID>) {
        let urls = ids.map { paths.itemFolder($0) }
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(urls)
    }

    /// Re-runs extraction for one item, ignoring the stage version so a manual
    /// press always does something.
    public func extract(_ id: CanonicalID) async {
        guard canExtract, !isExtracting.contains(id) else { return }
        guard var item = ItemStore(paths: paths).load(id) else { return }

        isExtracting.insert(id)
        defer { isExtracting.remove(id) }

        item.stages.extract = StageState()
        do {
            let updated = try await ExtractStage(secrets: secrets).run(item, paths: paths)
            try ItemStore(paths: paths).save(updated)
        } catch {
            Log.ui.error("extract failed for \(id.folderName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        reloadFromDisk()
    }

    // MARK: - Notion

    /// Checks for an existing row first. A duplicate raises a prompt rather than
    /// quietly adding a second copy — the same choice Finder gives you.
    public func push(_ resource: Resource, for item: CanonicalID, decision: DuplicateDecision? = nil) async {
        guard canPushToNotion,
              let token = secrets.value(for: .notionToken),
              let db = secrets.value(for: .notionResourcesDB)
        else { return }

        let client = NotionClient(token: token, databaseID: db)
        pushState[resource.id] = .working

        do {
            if decision == nil, let url = resource.url {
                let matches = try await client.findByURL(url)
                if !matches.isEmpty {
                    pushState[resource.id] = .idle
                    duplicatePrompt = DuplicatePrompt(
                        id: resource.id, resource: resource, matches: matches, item: item)
                    return
                }
            }
            if decision == .skip {
                pushState[resource.id] = .idle
                return
            }

            _ = try await client.create(resource)
            library.setPushed(resource.id, for: item, to: true)
            pushState[resource.id] = .pushed
            reloadFromDisk()
        } catch {
            pushState[resource.id] = .failed(error.localizedDescription)
            Log.ui.error("notion push failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    public func resolveDuplicate(_ decision: DuplicateDecision) async {
        guard let prompt = duplicatePrompt else { return }
        duplicatePrompt = nil

        switch decision {
        case .add:
            await push(prompt.resource, for: prompt.item, decision: .add)
        case .skip:
            // Treat a deliberate skip as settled so it stops being offered.
            library.setPushed(prompt.resource.id, for: prompt.item, to: true)
            reloadFromDisk()
        case .replace:
            pushState[prompt.resource.id] = .failed("Replacing an existing Notion page isn't supported yet")
        }
    }

    /// Pushes everything for one item that has not gone yet, stopping at the
    /// first duplicate so the prompt is never buried under later work.
    public func pushAll(for item: CanonicalID) async {
        for resource in resources(for: item) where !resource.pushedToNotion {
            await push(resource, for: item)
            if duplicatePrompt != nil { return }
        }
    }

    /// Rows for the selected source only.
    public var visibleRows: [QueueRow] {
        guard let platform = selectedSource.platform else { return [] }
        return rows.filter { $0.id.platform == platform }
    }

    /// Cached by `reloadFromDisk()` rather than filtering `rows` on every
    /// call — the sidebar reads this once per source per render.
    private var sourceCounts: [String: Int] = [:]

    public func count(for source: Source) -> Int { sourceCounts[source.id] ?? 0 }

    /// The folder on disk is the source of truth, so the queue is rebuilt from
    /// it rather than kept in memory across launches.
    public func reloadFromDisk() {
        rows = library.allItems().map { item in
            QueueRow(
                id: item.id,
                state: Self.state(of: item),
                title: Self.title(for: item),
                subtitle: Self.subtitle(for: item),
                folder: paths.itemFolder(item.id))
        }
        sourceCounts = Dictionary(uniqueKeysWithValues: Source.all.compactMap { source -> (String, Int)? in
            guard let platform = source.platform else { return nil }
            return (source.id, rows.filter { $0.id.platform == platform }.count)
        })
        everyResource = library.allResources()
    }

    static func state(of item: Item) -> ItemState {
        if let error = item.stages.fetch.error, !item.stages.fetch.done { return .dead(error) }
        if !item.stages.fetch.needsRun(currentVersion: StageVersions.fetch),
           !item.stages.transcribe.needsRun(currentVersion: StageVersions.transcribe),
           !item.stages.onscreen.needsRun(currentVersion: StageVersions.onscreen) {
            return .done
        }
        return .queued
    }

    /// The caption is what tells two posts apart. The author does not — a whole
    /// batch is often one account, which made every row read the same.
    static func title(for item: Item) -> String {
        let caption = (item.caption ?? "")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return caption.isEmpty ? item.id.folderName : caption
    }

    static func subtitle(for item: Item) -> String {
        let author = item.author.map { "@\($0)" }
        return [author, item.id.folderName].compactMap(\.self).joined(separator: "  ·  ")
    }

    // MARK: - intake

    public func accept(text: String) async {
        guard !isWorking, !isAccepting else { return }
        isAccepting = true
        intakeErrors = []
        defer { isAccepting = false }
        let result = await intake.intake(text: text)
        summary = result.summary
        intakeErrors = Array(Set(result.entries.compactMap { entry in
            if case .invalid(let message) = entry.disposition { return message }
            return nil
        })).sorted()
        do {
            try library.enqueue(result)
        } catch {
            intakeErrors.append("Could not save the queue: \(error.localizedDescription)")
        }
        reloadFromDisk()
    }

    public func accept(urls: [URL]) async {
        await accept(text: urls.map(\.absoluteString).joined(separator: "\n"))
    }

    public func clearSummary() {
        summary = nil
        intakeErrors = []
    }

    // MARK: - removing

    /// Deletes an item's folder and marks it `skipped` in the ledger.
    ///
    /// Both halves matter. Deleting the folder alone is how you ask for a redo,
    /// so the next paste would fetch it straight back — `skipped` is the
    /// project's existing "this is junk, never return" marker, and that is
    /// exactly what removing something means here.
    public func remove(_ id: CanonicalID) {
        do {
            let folder = paths.itemFolder(id)
            if FileManager.default.fileExists(atPath: folder.path()) {
                try FileManager.default.removeItem(at: folder)
            }
            try ledgerStore.update { $0[id] = LedgerEntry(status: .skipped, lastSeen: .neatNow) }
        } catch {
            Log.ui.error("could not remove \(id.folderName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
        reloadFromDisk()
    }

    /// Forgets the `skipped` marker so a removed item can be pasted again.
    public func unskip(_ id: CanonicalID) {
        try? ledgerStore.update { $0[id] = nil }
    }

    // MARK: - running

    public func runQueue() async {
        guard !isWorking, !isAccepting, preflight.isSatisfied else { return }
        isWorking = true
        defer { isWorking = false }

        let apply: @Sendable (LibraryEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.apply(event) }
        }
        await library.run(onEvent: apply)
        reloadFromDisk()
    }

    func apply(_ event: LibraryEvent) {
        guard let index = rows.firstIndex(where: { $0.id == event.id }) else { return }
        rows[index].state = event.state
    }
}

extension ItemState {
    public var label: String {
        switch self {
        case .queued: "Queued"
        case .fetching: "Fetching"
        case .listening: "Listening"
        case .reading: "Reading"
        case .done: "Done"
        case .dead: "Unavailable"
        case .skipped: "Skipped"
        }
    }

    public var icon: NeatIcon {
        switch self {
        case .queued: .queued
        case .fetching: .fetching
        case .listening: .listening
        case .reading: .reading
        case .done: .done
        case .dead: .unavailable
        case .skipped: .skipped
        }
    }

    public var isActive: Bool {
        switch self {
        case .fetching, .listening, .reading: true
        default: false
        }
    }
}

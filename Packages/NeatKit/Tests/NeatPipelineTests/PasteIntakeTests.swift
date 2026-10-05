import Foundation
import NeatAdapters
import NeatCore
import Testing

@testable import NeatPipeline

struct FixedResolver: RedirectResolver {
    let destinations: [String: String]
    func resolve(_ url: URL) async throws -> URL {
        guard let to = destinations[url.absoluteString], let d = URL(string: to) else {
            throw AdapterError.redirectFailed(url.absoluteString)
        }
        return d
    }
}

@Suite("Paste intake")
struct PasteIntakeTests {
    let paths: NeatPaths
    let intake: PasteIntake
    let ledgerStore: LedgerStore
    let items: ItemStore

    init() {
        paths = NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-intake-\(UUID().uuidString)"))
        ledgerStore = LedgerStore(paths: paths)
        items = ItemStore(paths: paths)
        intake = PasteIntake(
            adapters: [TikTokAdapter(resolver: FixedResolver(destinations: [
                "https://vm.tiktok.com/ZMabcdef/": "https://www.tiktok.com/@user/video/7381234567890"
            ]))],
            items: items,
            ledgerStore: ledgerStore)
    }

    func url(_ n: String) -> String { "https://www.tiktok.com/@user/video/\(n)" }

    func writeItem(_ native: String) throws {
        let id = CanonicalID(platform: .tiktok, nativeID: native)
        try items.save(Item(id: id, url: url(native), platform: .tiktok))
    }

    @Test("a fresh paste is all new")
    func allNew() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let result = await intake.intake(text: "\(url("7381234567890"))\n\(url("7381234567891"))")

        #expect(result.summary.new == 2)
        #expect(result.summary.line == "2 new, 0 already have, 0 unavailable")
        #expect(result.queued.count == 2)
    }

    @Test("a folder on disk means we already have it")
    func alreadyHave() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try writeItem("7381234567890")

        let result = await intake.intake(text: "\(url("7381234567890"))\n\(url("7381234567891"))")
        #expect(result.summary.alreadyHave == 1)
        #expect(result.summary.new == 1)
    }

    @Test("a dead ledger entry is unavailable, and is not queued")
    func deadIsUnavailable() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567890")
        try ledgerStore.update { $0[id] = LedgerEntry(status: .dead, attempts: 2) }

        let result = await intake.intake(text: url("7381234567890"))
        #expect(result.summary.unavailable == 1)
        #expect(result.queued.isEmpty)
    }

    @Test("a hand-skipped item never comes back")
    func skippedStaysSkipped() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567890")
        try ledgerStore.update { $0[id] = LedgerEntry(status: .skipped) }

        let result = await intake.intake(text: url("7381234567890"))
        #expect(result.summary.skipped == 1)
        #expect(result.queued.isEmpty)
    }

    /// Deleting a folder is how you ask for something to be redone. The ledger
    /// saying `done` must not veto that.
    @Test("ledger says done but the folder is gone: it is new again")
    func deletedFolderRequeues() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567890")
        try ledgerStore.update { $0[id] = LedgerEntry(status: .done) }

        let result = await intake.intake(text: url("7381234567890"))
        #expect(result.summary.new == 1)
        #expect(result.queued == [id])
    }

    @Test("a short link and its long form are one item, not two")
    func shortAndLongDedupe() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let text = "https://vm.tiktok.com/ZMabcdef/\n\(url("7381234567890"))"

        let result = await intake.intake(text: text)
        #expect(result.summary.total == 1)
        #expect(result.summary.new == 1)
    }

    @Test("junk in the paste is reported, not silently dropped")
    func junkIsCounted() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let text = "\(url("7381234567890"))\nhttps://example.com/nope\nsome words"

        let result = await intake.intake(text: text)
        #expect(result.summary.new == 1)
        #expect(result.summary.invalid == 1)
    }

    @Test("paste order is preserved so savedRank survives")
    func ordering() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let result = await intake.intake(text: "\(url("7381234567892"))\n\(url("7381234567890"))")
        #expect(result.queued.map(\.nativeID) == ["7381234567892", "7381234567890"])
    }

    @Test("a big mixed paste classifies every link exactly once")
    func bigBatch() async throws {
        defer { try? FileManager.default.removeItem(at: paths.root) }
        var lines: [String] = []
        for i in 0..<30 { lines.append(url("73812345670\(String(format: "%02d", i))")) }
        for i in 0..<5 { try writeItem("73812345670\(String(format: "%02d", i))") }

        let result = await intake.intake(text: lines.joined(separator: "\n"))
        #expect(result.summary.total == 30)
        #expect(result.summary.alreadyHave == 5)
        #expect(result.summary.new == 25)
    }

    @Test("empty paste yields an empty result")
    func emptyPaste() async throws {
        let result = await intake.intake(text: "   \n  ")
        #expect(result.entries.isEmpty)
        #expect(result.summary.total == 0)
    }
}

import Foundation
import Testing

@testable import NeatCore

@Suite("Ledger store")
struct LedgerStoreTests {
    func tempPaths() -> NeatPaths {
        NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-test-\(UUID().uuidString)"))
    }

    @Test("a missing ledger reads as empty rather than throwing")
    func missingIsEmpty() {
        #expect(LedgerStore(paths: tempPaths()).load().entries.isEmpty)
    }

    @Test("a corrupt ledger reads as empty rather than crashing")
    func corruptIsEmpty() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        try atomicWrite("{ this is not json", to: paths.ledger)

        #expect(LedgerStore(paths: paths).load().entries.isEmpty)
    }

    @Test("round-trips entries")
    func roundTrip() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = LedgerStore(paths: paths)
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567890")

        var ledger = Ledger()
        ledger[id] = LedgerEntry(status: .dead, lastSeen: .neatNow, attempts: 2)
        try store.save(ledger)

        let reloaded = store.load()
        #expect(reloaded[id]?.status == .dead)
        #expect(reloaded[id]?.attempts == 2)
        #expect(reloaded.contains(id))
    }

    @Test("update reads, mutates and writes in one go")
    func updateInPlace() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = LedgerStore(paths: paths)
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567890")

        try store.update { $0[id] = LedgerEntry(status: .queued) }
        try store.update { $0[id]?.status = .done }

        #expect(store.load()[id]?.status == .done)
    }

    @Test("the ledger file is human-readable JSON")
    func readableOnDisk() throws {
        let paths = tempPaths()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = LedgerStore(paths: paths)
        var ledger = Ledger()
        ledger[CanonicalID(platform: .tiktok, nativeID: "7381234567890")] = LedgerEntry(status: .done)
        try store.save(ledger)

        let text = try String(contentsOf: paths.ledger, encoding: .utf8)
        #expect(text.contains("tiktok-7381234567890"))
        #expect(text.contains("\n"))  // pretty-printed, so it diffs
    }
}

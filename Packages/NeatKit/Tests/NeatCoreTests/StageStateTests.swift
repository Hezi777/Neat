import Foundation
import Testing

@testable import NeatCore

@Suite("Stage versioning")
struct StageStateTests {
    @Test("a fresh stage needs running")
    func fresh() {
        #expect(StageState().needsRun(currentVersion: 1))
    }

    @Test("a stage done at the current version does not re-run")
    func doneAtCurrent() {
        #expect(!StageState.completed(v: 2).needsRun(currentVersion: 2))
    }

    @Test("bumping the version re-runs exactly that stage")
    func bumpForcesRerun() {
        #expect(StageState.completed(v: 1).needsRun(currentVersion: 2))
    }

    @Test("skipped never re-runs, even across a version bump")
    func skippedStaysSkipped() {
        let s = StageState.skippedStage(v: 1)
        #expect(!s.needsRun(currentVersion: 1))
        #expect(!s.needsRun(currentVersion: 99))
    }
}

@Suite("Atomic write")
struct AtomicWriteTests {
    @Test("writes, creates intermediate dirs, and overwrites in place")
    func writesAndReplaces() throws {
        let dir = URL.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appending(path: "nested").appending(path: "ledger.json")
        try atomicWrite("first", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "first")

        try atomicWrite("second", to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == "second")

        // No temp files left behind.
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: file.deletingLastPathComponent().path())
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test("timestamps are stored at a precision ISO-8601 can round-trip")
    func timestampsSurviveEncoding() throws {
        let stage = StageState.completed(v: 1, at: Date(timeIntervalSince1970: 1_757_000_000.987654))
        let decoded = try NeatJSON.decoder.decode(
            StageState.self, from: NeatJSON.encoder.encode(stage))
        #expect(decoded.at == stage.at)
    }

    @Test("item.json survives a JSON round trip")
    func itemRoundTrip() throws {
        let item = Item(
            id: CanonicalID(platform: .tiktok, nativeID: "7381234567890"),
            url: "https://www.tiktok.com/@u/video/7381234567890",
            platform: .tiktok,
            type: .slideshow,
            stages: Stages(fetch: .completed(v: 1), transcribe: .skippedStage(v: 1))
        )

        let data = try NeatJSON.encoder.encode(item)
        let decoded = try NeatJSON.decoder.decode(Item.self, from: data)
        #expect(decoded == item)
        #expect(decoded.stages.transcribe.skipped)
    }
}

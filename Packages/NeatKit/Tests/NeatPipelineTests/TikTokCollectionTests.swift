import Foundation
import NeatAdapters
import NeatCore
import Testing

@testable import NeatPipeline

@Suite("TikTok collections")
struct TikTokCollectionTests {
    static let collection = URL(string: "https://www.tiktok.com/@user/collection/AI-7599982720722815752")!
    static let first = URL(string: "https://www.tiktok.com/@first/video/7381234567890")!
    static let second = URL(string: "https://www.tiktok.com/@second/photo/7381234567891")!

    static let listing = #"""
    {"_type":"playlist","id":"7599982720722815752","entries":[
      {"id":"7381234567890","url":"https://www.tiktok.com/@first/video/7381234567890","extra":"ignored"},
      {"id":"7381234567891","webpage_url":"https://www.tiktok.com/@second/photo/7381234567891"}
    ]}
    """#

    @Test("flat listings preserve post order and photo URLs")
    func parse() throws {
        #expect(try TikTokCollection.parse(Data(Self.listing.utf8)) == [Self.first, Self.second])
    }

    @Test("incomplete or repeated pages never become successful partial imports", arguments: [
        "{}", "not json", #"{"_type":"playlist","entries":[]}"#,
        #"{"_type":"playlist","entries":[null]}"#,
        #"{"_type":"playlist","entries":[{"id":"7381234567890"}]}"#,
        #"{"_type":"playlist","entries":[{"id":"7381234567890","url":"https://example.com/video/7381234567890"}]}"#,
        #"{"_type":"playlist","entries":[{"id":"7381234567890","url":"https://www.tiktok.com/@u/video/7381234567891"}]}"#,
        #"{"_type":"playlist","entries":[{"id":"7381234567890","url":"https://www.tiktok.com/@u/video/7381234567890"},{"id":"7381234567890","url":"https://www.tiktok.com/@u/video/7381234567890"}]}"#,
    ])
    func rejectsIncomplete(raw: String) {
        #expect(throws: CollectionError.self) { try TikTokCollection.parse(Data(raw.utf8)) }
    }

    @Test("a collection expands before cross-link dedupe and respects existing folders")
    func intake() async throws {
        let paths = NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-collection-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let firstID = try #require(TikTokURL.canonicalID(from: Self.first))
        let secondID = try #require(TikTokURL.canonicalID(from: Self.second))
        let items = ItemStore(paths: paths)
        try items.save(Item(id: firstID, url: Self.first.absoluteString, platform: .tiktok))
        let intake = PasteIntake(items: items, ledgerStore: LedgerStore(paths: paths),
                                listCollection: { _ in [Self.first, Self.second] })
        let text = "\(Self.collection)\n\(Self.second)"
        let result = await intake.intake(text: text)
        #expect(result.summary.alreadyHave == 1)
        #expect(result.summary.new == 1)
        #expect(result.queued == [secondID])
        let library = Library(paths: paths, stages: [])
        try library.enqueue(result)
        #expect(items.load(secondID)?.url == Self.second.absoluteString)
        #expect(items.load(secondID)?.savedRank == 1)
        let again = await intake.intake(text: text)
        #expect(again.summary.new == 0)
        #expect(again.summary.alreadyHave == 2)
        #expect(library.allItems().count == 2)
    }

    @Test("a shortened collection link resolves before post identity is requested")
    func shortCollection() async throws {
        let short = "https://vt.tiktok.com/ZS9collection/"
        let adapter = TikTokAdapter(resolver: FixedResolver(destinations: [short: Self.collection.absoluteString]))
        let intake = PasteIntake(adapters: [adapter], listCollection: { url in
            #expect(url == Self.collection)
            return [Self.first, Self.second]
        })
        let result = await intake.intake(text: short)
        #expect(result.entries.map(\.raw) == [Self.first.absoluteString, Self.second.absoluteString])
        #expect(result.summary.invalid == 0)
    }

    @Test("listing errors remain actionable while other pasted posts still import")
    func listingFailure() async throws {
        let intake = PasteIntake(listCollection: { _ in throw CollectionError("Sign into TikTok in Chrome.") })
        let result = await intake.intake(text: "\(Self.collection)\n\(Self.first)")
        #expect(result.summary.invalid == 1)
        #expect(result.entries.first?.disposition == .invalid("Sign into TikTok in Chrome."))
        #expect(result.entries.last?.id == TikTokURL.canonicalID(from: Self.first))
    }

    @Test("overlapping collections preserve order and never requeue dead or skipped posts")
    func overlapping() async throws {
        let paths = NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-collection-\(UUID())"))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let ledger = LedgerStore(paths: paths)
        let firstID = try #require(TikTokURL.canonicalID(from: Self.first))
        let secondID = try #require(TikTokURL.canonicalID(from: Self.second))
        try ledger.update {
            $0[firstID] = LedgerEntry(status: .dead)
            $0[secondID] = LedgerEntry(status: .skipped)
        }
        let intake = PasteIntake(items: ItemStore(paths: paths), ledgerStore: ledger,
                                listCollection: { _ in [Self.first, Self.second] })
        let other = "https://www.tiktok.com/@user/collection/Other-7599982720722815753"
        let result = await intake.intake(text: "\(Self.collection)\n\(other)")
        #expect(result.entries.map(\.id) == [firstID, secondID])
        #expect(result.summary.unavailable == 1)
        #expect(result.summary.skipped == 1)
        #expect(result.queued.isEmpty)
    }

    @Test("listing uses Chrome cookies without media downloads and strips share tracking")
    func successfulProcess() async throws {
        let root = URL.temporaryDirectory.appending(path: "neat-listing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appending(path: "yt-dlp")
        let script = """
        #!/bin/sh
        printf '%s\\n' "$@" > "${0%/*}/arguments"
        cat <<'JSON'
        \(Self.listing)
        JSON
        """
        try script.write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path())
        let collection = TikTokCollection(preflight: ToolPreflight(searchPaths: [root.path()]))
        let shared = URL(string: "http://tiktok.com/@user/collection/AI-7599982720722815752?share_app_id=123&utm_source=copy#tracking")!

        #expect(try await collection.posts(in: shared) == [Self.first, Self.second])
        let arguments = try String(contentsOf: root.appending(path: "arguments"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
        #expect(arguments.contains("--flat-playlist"))
        #expect(arguments.contains("--dump-single-json"))
        #expect(arguments.contains("--skip-download"))
        let cookieIndex = try #require(arguments.firstIndex(of: "--cookies-from-browser"))
        #expect(arguments.dropFirst(cookieIndex + 1).first == "chrome")
        #expect(arguments.last == Self.collection.absoluteString)
    }

    @Test("missing yt-dlp gives installation guidance")
    func missingTool() async {
        let collection = TikTokCollection(preflight: ToolPreflight(searchPaths: []))
        do {
            _ = try await collection.posts(in: Self.collection)
            Issue.record("Expected missing yt-dlp to reject collection intake")
        } catch {
            #expect(error is CollectionError)
            #expect(error.localizedDescription == "Install yt-dlp to import TikTok collections.")
        }
    }

    @Test("failed yt-dlp exit rejects even a valid partial JSON payload")
    func failedProcess() async throws {
        let root = URL.temporaryDirectory.appending(path: "neat-listing-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appending(path: "yt-dlp")
        try "#!/bin/sh\ncat <<'JSON'\n\(Self.listing)\nJSON\nexit 1\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path())
        let collection = TikTokCollection(preflight: ToolPreflight(searchPaths: [root.path()]))
        await #expect(throws: CollectionError.self) { try await collection.posts(in: Self.collection) }
    }
}

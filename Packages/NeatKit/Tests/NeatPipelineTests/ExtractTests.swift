import Foundation
import Synchronization
import NeatCore
import Testing

@testable import NeatPipeline

@Suite(".env parsing")
struct SecretsStoreTests {
    func temp() -> URL {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "neat-secrets-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func store(file text: String, environment: [String: String] = [:]) throws -> SecretsStore {
        let root = temp()
        try Data(text.utf8).write(to: root.appending(path: ".env"))
        return SecretsStore(paths: NeatPaths(root: root), environment: environment)
    }

    @Test("reads plain, quoted, commented, blank and CRLF lines from a real file")
    func parsesRealFile() throws {
        let text = "# a comment\r\nGROQ_API_KEY=abc123\r\n\r\n"
            + "NOTION_RESOURCES_DB_ID=\"quoted-db\"\r\n"
            + "   # indented comment\r\n"
            + "SPACED  =  padded  \r\n"
            + "SINGLE='single quoted'\r\n"
        let store = try store(file: text)

        #expect(store.value(for: .groq) == "abc123")
        #expect(store.value(for: .notionResourcesDB) == "quoted-db")
        #expect(SecretsStore.parse(text)["SPACED"] == "padded")
        #expect(SecretsStore.parse(text)["SINGLE"] == "single quoted")
    }

    @Test("only the first = splits, so a value may contain more")
    func equalsInValue() {
        let parsed = SecretsStore.parse("A=b=c==d\nB==\n")
        #expect(parsed["A"] == "b=c==d")
        #expect(parsed["B"] == "=")
    }

    @Test("a # inside a value is part of the value, not a comment")
    func hashInValue() {
        #expect(SecretsStore.parse("K=abc#def\n")["K"] == "abc#def")
    }

    @Test("an unmatched quote is kept as part of the value")
    func unmatchedQuote() {
        #expect(SecretsStore.parse("K=\"half\n")["K"] == "\"half")
        #expect(SecretsStore.parse("K=\"\"\n")["K"] == "")
    }

    @Test("tolerates export prefixes, junk lines and a missing trailing newline")
    func forgiving() {
        let parsed = SecretsStore.parse("export A=1\nnot a pair\n=novalue\nB=2")
        #expect(parsed == ["A": "1", "B": "2"])
    }

    @Test("an empty or absent file yields nothing rather than failing")
    func emptyFile() {
        #expect(SecretsStore.parse("").isEmpty)
        let store = SecretsStore(paths: NeatPaths(root: temp()), environment: [:])
        #expect(store.value(for: .groq) == nil)
        #expect(!store.has(.groq))
    }

    @Test("the process environment wins over the file")
    func environmentWins() throws {
        let store = try store(file: "GROQ_API_KEY=from-file\n", environment: ["GROQ_API_KEY": "from-env"])
        #expect(store.value(for: .groq) == "from-env")
    }

    @Test("an empty environment value falls through to the file")
    func emptyEnvironmentValue() throws {
        let store = try store(file: "GROQ_API_KEY=from-file\n", environment: ["GROQ_API_KEY": ""])
        #expect(store.value(for: .groq) == "from-file")
    }

    @Test("a key added to the file after startup is picked up without a relaunch")
    func rereadsFile() throws {
        let root = temp()
        let store = SecretsStore(paths: NeatPaths(root: root), environment: [:])
        #expect(!store.has(.notionToken))

        try Data("NOTION_TOKEN=t\n".utf8).write(to: root.appending(path: ".env"))
        #expect(store.value(for: .notionToken) == "t")
    }
}

@Suite("Extract stage")
struct ExtractStageTests {
    func temp() -> NeatPaths {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "neat-extract-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return NeatPaths(root: dir)
    }

    func item() -> Item {
        Item(id: CanonicalID(platform: .tiktok, nativeID: "1"),
             url: "https://www.tiktok.com/@u/video/1",
             platform: .tiktok, type: .video, caption: "the caption")
    }

    /// A user with no Groq key must still get a working app: the stage marks
    /// itself not-applicable rather than throwing or staying pending forever.
    @Test("no key means skipped, not failed and not left undone")
    func noKeyIsSkipped() async throws {
        let paths = temp()
        let stage = ExtractStage(secrets: SecretsStore(paths: paths, environment: [:]))

        let out = try await stage.run(item(), paths: paths)

        #expect(out.stages.extract.skipped)
        #expect(!out.stages.extract.done)
        #expect(out.stages.extract.error == nil)
        #expect(!out.stages.extract.needsRun(currentVersion: StageVersions.extract))
        #expect(!FileManager.default.fileExists(atPath: paths.resources(out.id).path()))
    }

    @Test("an already-done item at the current version is left alone")
    func idempotent() async throws {
        let paths = temp()
        var input = item()
        input.stages.extract = .completed(v: StageVersions.extract)

        let out = try await ExtractStage(secrets: SecretsStore(paths: paths, environment: [:]))
            .run(input, paths: paths)

        #expect(out == input)
    }

    @Test("the context gathers caption, body, transcript and on-screen text")
    func contextAssembly() throws {
        let paths = temp()
        let item = item()
        try FileManager.default.createDirectory(at: paths.itemFolder(item.id), withIntermediateDirectories: true)
        try atomicWrite("the body", to: paths.body(item.id))
        try atomicWrite("the speech", to: paths.transcript(item.id))
        try atomicWrite("the overlay", to: paths.onscreen(item.id))

        let context = ExtractStage.context(for: item, paths: paths)
        #expect(context.contains("the caption"))
        #expect(context.contains("the body"))
        #expect(context.contains("the speech"))
        #expect(context.contains("the overlay"))
    }

    @Test("missing and empty files are simply absent from the context")
    func contextTolerant() throws {
        let paths = temp()
        var item = item()
        item.caption = nil
        #expect(ExtractStage.context(for: item, paths: paths) == "(no text available for this post)")
    }

    @Test("frames are spread across the post, not taken from the front")
    func evenlySpread() {
        let files = (0..<10).map { URL(filePath: "/f/frame-\($0).jpg") }
        let picked = ExtractStage.evenlySpread(files, cap: 5).map(\.lastPathComponent)
        #expect(picked == ["frame-0.jpg", "frame-2.jpg", "frame-5.jpg", "frame-7.jpg", "frame-9.jpg"])

        #expect(ExtractStage.evenlySpread(Array(files.prefix(3)), cap: 5).count == 3)
        #expect(ExtractStage.evenlySpread([], cap: 5).isEmpty)
        #expect(ExtractStage.evenlySpread(files, cap: 1).map(\.lastPathComponent) == ["frame-0.jpg"])
    }

    @Test("the request asks for the ten categories and nothing else")
    func schemaIsConstrained() throws {
        let format = ExtractStage.responseFormat
        #expect(format["type"] as? String == "json_schema")

        let schema = try #require((format["json_schema"] as? [String: Any])?["schema"] as? [String: Any])
        #expect((format["json_schema"] as? [String: Any])?["strict"] as? Bool == true)
        #expect(schema["additionalProperties"] as? Bool == false)

        let properties = try #require(schema["properties"] as? [String: Any])
        let array = try #require(properties["resources"] as? [String: Any])
        let object = try #require(array["items"] as? [String: Any])
        #expect(object["additionalProperties"] as? Bool == false)
        #expect(object["required"] as? [String] == ["name", "url", "category", "summary"])

        let fields = try #require(object["properties"] as? [String: Any])
        let category = try #require(fields["category"] as? [String: Any])
        let enumeration = (category["items"] as? [String: Any])?["enum"] as? [String]
        #expect(enumeration == Resource.categories)
    }
}

/// Saved response shapes, parsed offline. Nothing here touches the network.
@Suite("Groq response parsing")
struct GroqParsingTests {
    func envelope(_ content: String) -> Data {
        let escaped = String(decoding: try! JSONSerialization.data(
            withJSONObject: [content], options: .fragmentsAllowed), as: UTF8.self)
            .dropFirst().dropLast()
        return Data("""
            {"id":"chatcmpl-1","model":"\(ExtractStage.model)",
             "choices":[{"index":0,"message":{"role":"assistant","content":\(escaped)},
             "finish_reason":"stop"}]}
            """.utf8)
    }

    @Test("parses a normal result and normalizes its urls")
    func normal() throws {
        let resources = try ExtractStage.parse(envelope("""
            {"resources":[
              {"name":"Raycast","url":"https://www.raycast.com/?utm_source=tiktok",
               "category":["Tools"],"summary":"launcher the post demos"},
              {"name":"Some Library","url":null,"category":["GitHub","Dev Infrastructure"],
               "summary":"mentioned by name only"}]}
            """))

        #expect(resources.count == 2)
        #expect(resources[0].url == "https://raycast.com")
        #expect(resources[0].id == "https://raycast.com")
        #expect(resources[1].url == nil)
        #expect(resources[1].category == ["Dev Infrastructure", "GitHub"])
        #expect(resources.allSatisfy { !$0.pushedToNotion })
    }

    @Test("an empty array is a real answer, not an error")
    func empty() throws {
        #expect(try ExtractStage.parse(envelope(#"{"resources":[]}"#)).isEmpty)
    }

    @Test("a category the model invented is dropped, not substituted")
    func inventedCategory() throws {
        let resources = try ExtractStage.parse(envelope("""
            {"resources":[{"name":"X","url":null,"category":["Productivity","Tools"],"summary":"s"},
                          {"name":"Y","url":null,"category":["Productivity"],"summary":"s"}]}
            """))
        #expect(resources[0].category == ["Tools"])
        #expect(resources[1].category.isEmpty)
    }

    @Test("a nameless row is dropped rather than written as a blank resource")
    func namelessRow() throws {
        let resources = try ExtractStage.parse(envelope("""
            {"resources":[{"name":"","url":"https://example.com","category":[],"summary":"s"},
                          {"name":"Real","url":null,"category":[],"summary":"s"}]}
            """))
        #expect(resources.map(\.name) == ["Real"])
    }

    @Test("a response that is not the requested shape is surfaced, not swallowed")
    func badShape() {
        #expect(throws: StageError.self) { try ExtractStage.parse(Data(#"{"error":{"message":"nope"}}"#.utf8)) }
        #expect(throws: StageError.self) { try ExtractStage.parse(envelope("not json at all")) }
        #expect(throws: StageError.self) { try ExtractStage.parse(envelope(#"{"items":[]}"#)) }
    }
}

@Suite("Notion request shapes")
struct NotionClientTests {
    let resource = Resource(
        id: "https://raycast.com", name: "Raycast", url: "https://raycast.com",
        category: ["Tools", "Productivity"], summary: "a launcher")

    @Test("a page uses the database's real property names and always sends Saved")
    func propertyShape() throws {
        let properties = NotionClient.properties(for: resource)
        let json = try JSONSerialization.data(withJSONObject: properties)
        let root = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])

        #expect(Set(root.keys) == ["Name", "URL", "Status", "Category", "Description"])

        let status = try #require(root["Status"] as? [String: Any])
        #expect((status["select"] as? [String: Any])?["name"] as? String == "Saved")

        let category = try #require(root["Category"] as? [String: Any])
        let names = (category["multi_select"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
        #expect(names == ["Tools"])  // the invented one never reaches Notion

        #expect((root["URL"] as? [String: Any])?["url"] as? String == "https://raycast.com")
    }

    @Test("a resource with no url omits the property rather than sending an empty string")
    func noURL() {
        var bare = resource
        bare.url = nil
        #expect(NotionClient.properties(for: bare)["URL"] == nil)
    }

    @Test("reads page id, title and url out of a saved query response")
    func parsesQueryResponse() throws {
        let data = Data("""
            {"object":"list","results":[
              {"object":"page","id":"page-1","properties":{
                 "Name":{"title":[{"plain_text":"Raycast"}]},
                 "URL":{"url":"https://www.raycast.com/?utm_source=x"}}},
              {"object":"page","id":"page-2","properties":{
                 "Name":{"title":[{"plain_text":"Something else"}]},
                 "URL":{"url":"https://example.com"}}}],
             "has_more":false}
            """.utf8)

        let matches = NotionClient.matches(in: data)
        #expect(matches.count == 2)
        #expect(matches[0] == NotionMatch(pageID: "page-1", title: "Raycast",
                                          url: "https://www.raycast.com/?utm_source=x"))

        // The stored URL differs from ours character for character; the same
        // normalizer that made the resource id is what decides they match.
        let same = matches.filter { ResourceURL.sameResource($0.url, "https://raycast.com/") }
        #expect(same.map(\.pageID) == ["page-1"])
    }

    @Test("an unparseable query response yields no matches rather than crashing")
    func junkResponse() {
        #expect(NotionClient.matches(in: Data("not json".utf8)).isEmpty)
        #expect(NotionClient.matches(in: Data(#"{"results":[{"no":"id"}]}"#.utf8)).isEmpty)
    }

    @Test("replace is not implemented yet and says so")
    func replaceThrows() async {
        let client = NotionClient(token: "t", databaseID: "d")
        await #expect(throws: StageError.self) { try await client.push(resource, decision: .replace) }
        #expect(try! await client.push(resource, decision: .skip) == nil)
    }
}

@Suite("Library resources")
struct LibraryResourceTests {
    func library() -> Library {
        let dir = URL(filePath: NSTemporaryDirectory()).appending(path: "neat-lib-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return Library(paths: NeatPaths(root: dir), stages: [])
    }

    func seed(_ library: Library, _ nativeID: String, _ resources: [Resource]) throws -> Item {
        let item = Item(id: CanonicalID(platform: .tiktok, nativeID: nativeID),
                        url: "https://www.tiktok.com/@u/video/\(nativeID)",
                        platform: .tiktok, savedRank: Int(nativeID))
        try ItemStore(paths: library.paths).save(item)
        try atomicWriteJSON(ResourcesFile(resources: resources), to: library.paths.resources(item.id))
        return item
    }

    func resource(_ id: String, pushed: Bool = false) -> Resource {
        Resource(id: id, name: id, url: nil, category: ["Tools"], summary: "s", pushedToNotion: pushed)
    }

    @Test("reads an item's resources back off disk, and nothing for an item with none")
    func readsResources() throws {
        let library = library()
        let item = try seed(library, "1", [resource("a"), resource("b", pushed: true)])

        #expect(library.resources(for: item.id).map(\.id) == ["a", "b"])
        #expect(library.resources(for: CanonicalID(platform: .tiktok, nativeID: "999")).isEmpty)
    }

    @Test("allResources pairs every resource with its item, in item order")
    func allResources() throws {
        let library = library()
        _ = try seed(library, "2", [resource("c")])
        _ = try seed(library, "1", [resource("a"), resource("b")])

        let all = library.allResources()
        #expect(all.map(\.resource.id) == ["a", "b", "c"])
        #expect(all.map(\.item.id.nativeID) == ["1", "1", "2"])
    }

    @Test("setPushed persists and is readable back")
    func setPushed() throws {
        let library = library()
        let item = try seed(library, "1", [resource("a"), resource("b")])

        library.setPushed("a", for: item.id, to: true)
        #expect(library.resources(for: item.id).map(\.pushedToNotion) == [true, false])

        library.setPushed("a", for: item.id, to: false)
        #expect(library.resources(for: item.id).map(\.pushedToNotion) == [false, false])
    }

    @Test("setPushed on an unknown id changes nothing")
    func setPushedUnknown() throws {
        let library = library()
        let item = try seed(library, "1", [resource("a")])

        library.setPushed("missing", for: item.id, to: true)
        #expect(library.resources(for: item.id) == [resource("a")])
    }

    @Test("a corrupt resources.json reads as empty rather than taking the app down")
    func corruptFile() throws {
        let library = library()
        let item = try seed(library, "1", [resource("a")])
        try atomicWrite("{ not json", to: library.paths.resources(item.id))
        #expect(library.resources(for: item.id).isEmpty)
    }
}

/// Replays a scripted sequence of HTTP replies, so the retry loop can be driven
/// through a rate limit and out the other side without a network.
final class ScriptedURLProtocol: URLProtocol {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    static let replies = Mutex<[Reply]>([])
    static let requests = Mutex<Int>(0)

    static func script(_ replies: [Reply]) {
        Self.replies.withLock { $0 = replies }
        Self.requests.withLock { $0 = 0 }
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ScriptedURLProtocol.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let next = Self.replies.withLock { $0.isEmpty ? nil : $0.removeFirst() }

        guard let next, let url = request.url,
              let response = HTTPURLResponse(
                url: url, statusCode: next.status, httpVersion: nil, headerFields: next.headers)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: next.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The live API's two rejections look alike and are not alike: a 429 is worth
/// waiting out, a 413 never is — Groq sends `retry-after` on both.
// `.serialized` because the scripted replies are one shared queue — run in
// parallel, these tests drain each other and fail as "bad server response".
@Suite("Extract rate limiting", .serialized)
struct ExtractRateLimitTests {
    /// One line on purpose: a line break inside the `content` string is a raw
    /// control character and makes the envelope invalid JSON.
    static let goodBody = Data(
        #"{"choices":[{"message":{"content":"{\"resources\":[{\"name\":\"Raycast\",\"url\":\"https://raycast.com\",\"category\":[\"Tools\"],\"summary\":\"A launcher.\"}]}"}}]}"#.utf8)

    static let rateLimitBody = Data(#"{"error":{"message":"Rate limit reached","code":"rate_limit_exceeded"}}"#.utf8)
    static let tooLargeBody = Data(#"{"error":{"message":"Request too large ... Limit 7000, Requested 7683"}}"#.utf8)

    func fixture() throws -> (NeatPaths, Item) {
        let root = URL.temporaryDirectory.appending(path: "neat-extract-rl-\(UUID().uuidString)")
        let paths = NeatPaths(root: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("GROQ_API_KEY=test-key\n".utf8).write(to: root.appending(path: ".env"))

        let item = Item(
            id: CanonicalID(platform: .tiktok, nativeID: "7381234567890"),
            url: "https://www.tiktok.com/@u/video/7381234567890",
            platform: .tiktok, type: .video,
            stages: Stages(fetch: .completed(v: StageVersions.fetch)))
        return (paths, item)
    }

    func stage(_ paths: NeatPaths) -> ExtractStage {
        ExtractStage(
            secrets: SecretsStore(paths: paths, environment: [:]),
            session: ScriptedURLProtocol.session())
    }

    /// The point of the whole change: a rate limit costs time, not the item.
    @Test("a 429 is waited out and the next attempt succeeds")
    func retriesThroughRateLimit() async throws {
        let (paths, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        ScriptedURLProtocol.script([
            .init(status: 429, headers: ["retry-after": "1"], body: Self.rateLimitBody),
            .init(status: 200, headers: [:], body: Self.goodBody),
        ])

        let out = try await stage(paths).run(item, paths: paths)

        #expect(out.stages.extract.done)
        #expect(ScriptedURLProtocol.requests.withLock { $0 } == 2)
        #expect(ExtractStage.loadResources(paths.resources(item.id)).first?.name == "Raycast")
    }

    /// Exhausted retries must still be `rateLimited`, so `Library` withholds the
    /// attempt rather than counting it as the item's fault.
    @Test("a persistent 429 surfaces as rateLimited, not a plain failure")
    func persistentRateLimitStaysRateLimited() async throws {
        let (paths, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // A short `retry-after` on every reply: the waits are real sleeps, and
        // without it this test alone spends ten seconds proving nothing extra.
        ScriptedURLProtocol.script(
            Array(repeating: .init(status: 429, headers: ["retry-after": "1"], body: Self.rateLimitBody),
                  count: ExtractStage.rateLimitRetries))

        do {
            _ = try await stage(paths).run(item, paths: paths)
            Issue.record("expected a rate limit to be thrown")
        } catch let error as StageError {
            guard case .rateLimited = error else {
                Issue.record("expected .rateLimited, got \(error)")
                return
            }
        }
        #expect(ScriptedURLProtocol.requests.withLock { $0 } == ExtractStage.rateLimitRetries)
    }

    /// 413 means the payload never fits. Retrying it is just the same mistake,
    /// more slowly — and it must not masquerade as a transient rate limit.
    @Test("a 413 fails immediately and says what would help")
    func tooLargeIsNotRetried() async throws {
        let (paths, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        // Groq sends retry-after on a 413 too. It must not be believed.
        ScriptedURLProtocol.script([
            .init(status: 413, headers: ["retry-after": "2"], body: Self.tooLargeBody),
            .init(status: 200, headers: [:], body: Self.goodBody),
        ])

        do {
            _ = try await stage(paths).run(item, paths: paths)
            Issue.record("expected a 413 to throw")
        } catch let error as StageError {
            guard case .fetchFailed(let why) = error else {
                Issue.record("a 413 must not be reported as a rate limit")
                return
            }
            #expect(why.contains("maxImages"))
        }
        #expect(ScriptedURLProtocol.requests.withLock { $0 } == 1)
    }
}

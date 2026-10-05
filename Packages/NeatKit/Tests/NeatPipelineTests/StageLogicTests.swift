import Foundation
import NeatCore
import Testing

@testable import NeatPipeline

@Suite("Type detection")
struct TypeDetectorTests {
    func info(json: String) throws -> MediaInfo {
        try JSONDecoder().decode(MediaInfo.self, from: Data(json.utf8))
    }

    func url(_ s: String) throws -> URL { try #require(URL(string: s)) }

    @Test("a normal video with a video stream is a video")
    func video() throws {
        let i = try info(json: #"{"id":"1","vcodec":"h264","duration":58}"#)
        #expect(TypeDetector.detect(info: i, sourceURL: try url("https://www.tiktok.com/@u/video/7381234567890")) == .video)
    }

    /// The strongest signal: the payload literally carries slide images.
    @Test("slide images in the payload mean slideshow, whatever the URL says")
    func slidesWin() throws {
        let i = try info(json: #"{"id":"1","vcodec":"h264","images":[{"url":"https://x/1.jpg"},{"url":"https://x/2.jpg"}]}"#)
        #expect(TypeDetector.detect(info: i, sourceURL: try url("https://www.tiktok.com/@u/video/7381234567890")) == .slideshow)
    }

    /// yt-dlp rendered the slides into an mp4 instead of listing them.
    @Test("a photo URL that came back as video is still a slideshow")
    func renderedSlideshow() throws {
        let i = try info(json: #"{"id":"1","vcodec":"h264","duration":12}"#)
        #expect(TypeDetector.detect(info: i, sourceURL: try url("https://www.tiktok.com/@u/photo/7381234567890")) == .slideshow)
    }

    @Test("a photo URL with neither images nor video is still a slideshow")
    func bareePhotoPost() throws {
        let i = try info(json: #"{"id":"1"}"#)
        #expect(TypeDetector.detect(info: i, sourceURL: try url("https://www.tiktok.com/@u/photo/7381234567890")) == .slideshow)
    }

    @Test("unknown keys in yt-dlp's json do not break decoding")
    func toleratesUnknownKeys() throws {
        let i = try info(json: #"{"id":"1","vcodec":"h264","some_new_key_2027":{"a":1},"duration":5}"#)
        #expect(i.id == "1")
        #expect(i.hasVideoStream)
    }

    @Test("reads author, caption and upload date the way yt-dlp reports them")
    func metadata() throws {
        let i = try info(json: #"{"id":"1","uploader":"someone","description":"the caption","upload_date":"20260904","vcodec":"h264"}"#)
        #expect(i.author == "someone")
        #expect(i.caption == "the caption")
        #expect(i.uploadedAt != nil)
    }

    @Test("a timestamp wins over upload_date and is stored at second precision")
    func timestampPreferred() throws {
        let i = try info(json: #"{"id":"1","timestamp":1757000000.9,"upload_date":"20200101"}"#)
        let date = try #require(i.uploadedAt)
        #expect(date == date.neatTruncated)
    }
}

@Suite("Transcribe skipping")
struct TranscribeSkipTests {
    let paths = NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-skip-\(UUID().uuidString)"))

    func item(_ type: ItemType) -> Item {
        Item(id: CanonicalID(platform: .tiktok, nativeID: "7381234567890"),
             url: "https://www.tiktok.com/@u/video/7381234567890",
             platform: .tiktok, type: type,
             stages: Stages(fetch: .completed(v: StageVersions.fetch)))
    }

    /// Without this the resume sweep retries a silent slideshow forever.
    @Test("a slideshow is marked skipped, not left undone", arguments: [ItemType.slideshow, .image])
    func skipsTypelessAudio(type: ItemType) async throws {
        let result = try await TranscribeStage().run(item(type), paths: paths)
        #expect(result.stages.transcribe.skipped)
        #expect(!result.stages.transcribe.done)
        #expect(!result.stages.transcribe.needsRun(currentVersion: StageVersions.transcribe))
    }

    @Test("a video with no audio file is a real failure, not a skip")
    func missingAudioThrows() async {
        await #expect(throws: StageError.self) {
            _ = try await TranscribeStage().run(item(.video), paths: paths)
        }
    }

    @Test("an already-skipped stage is not re-run")
    func doesNotRerunSkipped() async throws {
        var i = item(.slideshow)
        i.stages.transcribe = .skippedStage(v: StageVersions.transcribe)
        let result = try await TranscribeStage().run(i, paths: paths)
        #expect(result.stages.transcribe.skipped)
    }
}

@Suite("Frame extraction helpers")
struct FrameExtractorTests {
    /// URL.appending percent-encodes '%', which hands ffmpeg frame-%2502d.jpg.
    @Test("the ffmpeg output pattern keeps a literal percent")
    func patternIsLiteral() {
        let dir = URL.temporaryDirectory.appending(path: "frames", directoryHint: .isDirectory)
        let pattern = FrameExtractor.outputPattern(in: dir)
        #expect(pattern.hasSuffix("/frame-%02d.jpg"))
        #expect(!pattern.contains("%25"))
        #expect(!pattern.contains("//frame"))
    }

    @Test("frames are named in a stable sortable order")
    func frameNaming() {
        #expect(FrameExtractor.frameName(0) == "frame-00.jpg")
        #expect(FrameExtractor.frameName(7) == "frame-07.jpg")
        #expect(FrameExtractor.frameName(12) == "frame-12.jpg")
    }

    @Test("trimming keeps an evenly spread subset and renumbers without gaps")
    func trimSpreads() throws {
        let dir = URL.temporaryDirectory.appending(path: "neat-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for i in 0..<20 {
            try Data("x".utf8).write(to: dir.appending(path: FrameExtractor.frameName(i)))
        }

        let extractor = FrameExtractor(ffmpeg: "/usr/bin/true")
        try extractor.trimFrames(in: dir, to: 8)

        let names = try extractor.frameFiles(in: dir).map { $0.lastPathComponent }
        #expect(names.count == 8)
        #expect(names == (0..<8).map(FrameExtractor.frameName))
    }
}

/// A stage that fails on demand, so `Library`'s failure accounting can be
/// tested without a network or a real stage.
struct ThrowingStage: Stage {
    let name: String
    let version: Int
    let error: StageError

    func run(_ item: Item, paths: NeatPaths) async throws -> Item { throw error }
}

/// An item's two attempts are for the item being wrong. Spending one because a
/// shared quota was busy is how a whole collection dies for no reason — the
/// posts were fine, the afternoon was.
@Suite("Rate limits do not kill items")
struct RateLimitAccountingTests {
    func fixture() throws -> (NeatPaths, Item) {
        let root = URL.temporaryDirectory.appending(path: "neat-ratelimit-\(UUID().uuidString)")
        let paths = NeatPaths(root: root)
        let item = Item(
            id: CanonicalID(platform: .tiktok, nativeID: "7381234567890"),
            url: "https://www.tiktok.com/@u/video/7381234567890",
            platform: .tiktok, type: .video,
            stages: Stages(
                fetch: .completed(v: StageVersions.fetch),
                transcribe: .skippedStage(v: StageVersions.transcribe),
                onscreen: .skippedStage(v: StageVersions.onscreen)))
        try ItemStore(paths: paths).save(item)
        return (paths, item)
    }

    func library(_ paths: NeatPaths, throwing error: StageError) -> Library {
        Library(paths: paths, stages: [
            ThrowingStage(name: "extract", version: StageVersions.extract, error: error),
        ])
    }

    @Test("a rate limit costs the item nothing")
    func rateLimitDoesNotCount() async throws {
        let (paths, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        await library(paths, throwing: .rateLimited(retryAfter: nil, detail: "busy"))
            .process(item)

        let entry = try #require(LedgerStore(paths: paths).load()[item.id])
        #expect(entry.attempts == 0)
        #expect(entry.status == .queued)
    }

    /// Even repeatedly. This is the case that used to kill a collection.
    @Test("ten rate limits in a row still leave the item alive")
    func rateLimitNeverKills() async throws {
        let (paths, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = library(paths, throwing: .rateLimited(retryAfter: nil, detail: "busy"))

        for _ in 0..<10 { await library.process(item) }

        let entry = try #require(LedgerStore(paths: paths).load()[item.id])
        #expect(entry.attempts == 0)
        #expect(entry.status == .queued)
    }

    /// The reason still reaches the item, so a stalled row can explain itself.
    @Test("the rate limit is still recorded on the item")
    func reasonIsRecorded() async throws {
        let (paths, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }

        await library(paths, throwing: .rateLimited(retryAfter: nil, detail: "quota gone"))
            .process(item)

        let saved = try #require(ItemStore(paths: paths).load(item.id))
        #expect(saved.stages.extract.error?.contains("quota gone") == true)
        #expect(!saved.stages.extract.done)
    }

    /// The control: an ordinary failure must still count, or nothing ever dies.
    @Test("an ordinary failure still costs an attempt, and two still kill it")
    func ordinaryFailureStillCounts() async throws {
        let (paths, item) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let library = library(paths, throwing: .fetchFailed("genuinely broken"))

        await library.process(item)
        #expect(LedgerStore(paths: paths).load()[item.id]?.attempts == 1)
        #expect(LedgerStore(paths: paths).load()[item.id]?.status == .queued)

        await library.process(item)
        let entry = try #require(LedgerStore(paths: paths).load()[item.id])
        #expect(entry.attempts == 2)
        #expect(entry.status == .dead)
    }
}

@Suite("Groq retry-after")
struct RetryAfterTests {
    func response(_ headers: [String: String], status: Int = 429) throws -> HTTPURLResponse {
        let url = try #require(URL(string: "https://api.groq.com/openai/v1/chat/completions"))
        return try #require(HTTPURLResponse(
            url: url, statusCode: status, httpVersion: nil, headerFields: headers))
    }

    @Test("takes the service's own figure rather than guessing")
    func readsHeader() throws {
        #expect(try ExtractStage.retryAfter(response(["retry-after": "2"])) == .seconds(2))
    }

    /// One item must not be able to stall the sweep for a quarter of an hour.
    @Test("an absurd wait is clamped")
    func clampsLongWaits() throws {
        #expect(try ExtractStage.retryAfter(response(["retry-after": "900"])) == .seconds(60))
    }

    @Test("a missing or unusable header is nil, not a fabricated wait")
    func missingHeader() throws {
        #expect(try ExtractStage.retryAfter(response([:])) == nil)
        #expect(try ExtractStage.retryAfter(response(["retry-after": "soon"])) == nil)
        #expect(try ExtractStage.retryAfter(response(["retry-after": "0"])) == nil)
    }
}

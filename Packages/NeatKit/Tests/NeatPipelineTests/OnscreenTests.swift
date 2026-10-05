import CoreGraphics
import Foundation
import ImageIO
import NeatCore
import Synchronization
import Testing
import UniformTypeIdentifiers

@testable import NeatPipeline

@Suite("Fallback routing")
struct FallbackRoutingTests {
    func result(lines: [String], confidence: Float) -> FrameText {
        FrameText(frame: URL(filePath: "/tmp/f.jpg"), lines: lines, confidence: confidence,
                  containsNonLatin: lines.contains(where: VisionOCR.hasNonLatinScript))
    }

    @Test("confident Latin text stays local — no API call")
    func confidentLatinStaysLocal() {
        #expect(!VisionOCR.needsFallback(result(lines: ["brew install yt-dlp"], confidence: 0.95)))
    }

    @Test("a frame Vision could not read at all goes to the API")
    func emptyGoesToAPI() {
        #expect(VisionOCR.needsFallback(result(lines: [], confidence: 0)))
    }

    @Test("low confidence goes to the API")
    func lowConfidenceGoesToAPI() {
        #expect(VisionOCR.needsFallback(result(lines: ["sornethlng"], confidence: 0.2)))
    }

    /// Vision handles Hebrew far less reliably than Latin, so it is re-read even
    /// when Vision itself claims high confidence.
    @Test("Hebrew goes to the API even at high confidence")
    func hebrewGoesToAPI() {
        #expect(VisionOCR.needsFallback(result(lines: ["שלום עולם"], confidence: 0.99)))
    }

    @Test("detects Hebrew and Arabic, not Latin or digits")
    func scriptDetection() {
        #expect(VisionOCR.hasNonLatinScript("שלום"))
        #expect(VisionOCR.hasNonLatinScript("mixed שלום english"))
        #expect(!VisionOCR.hasNonLatinScript("git commit -m 'fix'"))
        #expect(!VisionOCR.hasNonLatinScript("12345 --flag"))
    }
}

@Suite("Anthropic fallback")
struct AnthropicOCRTests {
    @Test("parses text out of a real response shape")
    func parsesResponse() throws {
        let json = """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-sonnet-4-6",
         "content":[{"type":"text","text":"brew install yt-dlp"}],
         "stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}
        """
        #expect(try AnthropicOCR.extractText(Data(json.utf8)) == "brew install yt-dlp")
    }

    @Test("joins multiple text blocks and ignores non-text ones")
    func joinsBlocks() throws {
        let json = """
        {"content":[{"type":"thinking","thinking":"..."},
                    {"type":"text","text":"line one\\n"},
                    {"type":"text","text":"line two"}]}
        """
        #expect(try AnthropicOCR.extractText(Data(json.utf8)) == "line one\nline two")
    }

    @Test("an unexpected response shape throws rather than returning nonsense")
    func rejectsGarbage() {
        #expect(throws: StageError.self) {
            _ = try AnthropicOCR.extractText(Data(#"{"error":{"type":"overloaded_error"}}"#.utf8))
        }
    }

    /// Tokens are the cost, and OCR does not need full resolution.
    @Test("downscales a large frame to the long edge and re-encodes as JPEG")
    func downscales() throws {
        let dir = URL.temporaryDirectory.appending(path: "neat-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let big = dir.appending(path: "big.jpg")
        let ctx = CGContext(data: nil, width: 2000, height: 3000, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 2000, height: 3000))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(big as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        let data = try #require(AnthropicOCR.downscaledJPEG(big))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let out = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(out.width, out.height) <= Int(AnthropicOCR.maxDimension))
    }
}

@Suite("Onscreen stage")
struct OnscreenStageTests {
    func item() -> Item {
        Item(id: CanonicalID(platform: .tiktok, nativeID: "7381234567890"),
             url: "https://www.tiktok.com/@u/video/7381234567890",
             platform: .tiktok, type: .video,
             stages: Stages(fetch: .completed(v: StageVersions.fetch)))
    }

    /// No frames means fetch produced none. Writing an empty onscreen.txt would
    /// mark the stage done and hide a real fetch failure.
    @Test("no frames is a failure, not an empty result")
    func noFramesThrows() async {
        let paths = NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-noframes-\(UUID().uuidString)"))
        await #expect(throws: StageError.self) {
            _ = try await OnscreenStage().run(item(), paths: paths)
        }
    }

    @Test("an already-done stage is not re-run")
    func skipsWhenDone() async throws {
        let paths = NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-done-\(UUID().uuidString)"))
        var i = item()
        i.stages.onscreen = .completed(v: StageVersions.onscreen)
        let out = try await OnscreenStage().run(i, paths: paths)
        #expect(out.stages.onscreen.done)
    }

    func threadsItem(fetchDone: Bool) -> Item {
        Item(id: CanonicalID(platform: .threads, nativeID: "abc123"),
             url: "https://www.threads.net/t/abc123",
             platform: .threads, type: .image,
             stages: Stages(fetch: fetchDone ? .completed(v: StageVersions.fetch) : StageState()))
    }

    /// A text-only Threads post never had attachments to put in `frames/` —
    /// that is not a fetch failure, so the stage should skip rather than throw.
    @Test("a text-only Threads post skips instead of throwing")
    func threadsNoAttachmentsSkips() async throws {
        let paths = NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-threads-skip-\(UUID().uuidString)"))
        let out = try await OnscreenStage().run(threadsItem(fetchDone: true), paths: paths)
        #expect(out.stages.onscreen.skipped)
        #expect(!out.stages.onscreen.done)
    }

    /// Empty `frames/` on a Threads item whose fetch never actually completed
    /// must still be treated as a real failure — platform alone is not enough
    /// to justify skipping, or a genuine fetch failure would be hidden.
    @Test("a Threads item with empty frames but an incomplete fetch still throws")
    func threadsIncompleteFetchStillThrows() async {
        let paths = NeatPaths(root: URL.temporaryDirectory.appending(path: "neat-threads-fail-\(UUID().uuidString)"))
        await #expect(throws: StageError.self) {
            _ = try await OnscreenStage().run(threadsItem(fetchDone: false), paths: paths)
        }
    }

    /// Populated frames must still be read normally — the empty-frames guard
    /// must not change behavior when there is actually something to read.
    @Test("populated frames are still read and the stage completes")
    func populatedFramesUnchanged() async throws {
        let root = URL.temporaryDirectory.appending(path: "neat-populated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NeatPaths(root: root)
        let framesDir = paths.frames(item().id)
        try FileManager.default.createDirectory(at: framesDir, withIntermediateDirectories: true)

        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(
            framesDir.appending(path: "frame-00.jpg") as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        let out = try await OnscreenStage().run(item(), paths: paths)
        #expect(out.stages.onscreen.done)
        #expect(!out.stages.onscreen.skipped)
    }

    @Test("only image files count as frames, in stable order")
    func picksImagesInOrder() throws {
        let dir = URL.temporaryDirectory.appending(path: "neat-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for name in ["frame-02.jpg", "frame-00.jpg", "frame-01.png", "notes.txt", ".DS_Store"] {
            try Data("x".utf8).write(to: dir.appending(path: name))
        }

        let files = OnscreenStage.frameFiles(in: dir).map(\.lastPathComponent)
        #expect(files == ["frame-00.jpg", "frame-01.png", "frame-02.jpg"])
    }
}

/// Fails every request without touching the network. The stage's contract on a
/// failed fallback is to keep whatever Vision already read, so a canned failure
/// is all this needs — the point of these tests is *which key* got resolved.
final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}

/// The Anthropic key must resolve the same way every other credential does —
/// environment, then `~/Neat/.env`, then the Keychain. This stage read the
/// Keychain directly, so a key in `.env` was silently dead here and the
/// fallback was unreachable for anyone who had only ever used `.env`.
@Suite("Onscreen key resolution")
struct OnscreenKeyResolutionTests {
    /// A blank frame is one Vision reads nothing off, which is exactly the
    /// condition that sends a frame to the fallback.
    func writeBlankFrame(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ctx = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(dest))
    }

    func failingSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        return URLSession(configuration: config)
    }

    func item(_ id: CanonicalID) -> Item {
        Item(id: id, url: "https://www.tiktok.com/@u/video/\(id.nativeID)",
             platform: .tiktok, type: .video,
             stages: Stages(fetch: .completed(v: StageVersions.fetch)))
    }

    /// The regression: the key lives only in `<root>/.env`, nowhere else.
    /// The environment is passed empty so a key in the developer's own shell
    /// cannot make this pass for the wrong reason.
    @Test("a key in .env reaches the fallback")
    func envFileKeyIsUsed() async throws {
        let root = URL.temporaryDirectory.appending(path: "neat-envkey-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NeatPaths(root: root)
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567890")
        try writeBlankFrame(at: paths.frames(id).appending(path: "frame-00.jpg"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("ANTHROPIC_API_KEY=env-file-key\n".utf8).write(to: root.appending(path: ".env"))

        let seen = Mutex<String?>(nil)
        let session = failingSession()
        let stage = OnscreenStage(
            secrets: SecretsStore(paths: paths, environment: [:]),
            makeFallback: { key in
                seen.withLock { $0 = key }
                return AnthropicOCR(apiKey: key, session: session)
            })

        let out = try await stage.run(item(id), paths: paths)

        #expect(seen.withLock { $0 } == "env-file-key")
        // A failed fallback must not cost the stage its result.
        #expect(out.stages.onscreen.done)
    }

    /// The environment wins over the file, so a terminal run of `neat-cli` can
    /// override whatever the app has stored.
    @Test("the environment beats the .env file")
    func environmentWins() async throws {
        let root = URL.temporaryDirectory.appending(path: "neat-envwin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = NeatPaths(root: root)
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567891")
        try writeBlankFrame(at: paths.frames(id).appending(path: "frame-00.jpg"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("ANTHROPIC_API_KEY=file-key\n".utf8).write(to: root.appending(path: ".env"))

        let seen = Mutex<String?>(nil)
        let session = failingSession()
        let stage = OnscreenStage(
            secrets: SecretsStore(paths: paths, environment: ["ANTHROPIC_API_KEY": "env-key"]),
            makeFallback: { key in
                seen.withLock { $0 = key }
                return AnthropicOCR(apiKey: key, session: session)
            })

        _ = try await stage.run(item(id), paths: paths)

        #expect(seen.withLock { $0 } == "env-key")
    }
}

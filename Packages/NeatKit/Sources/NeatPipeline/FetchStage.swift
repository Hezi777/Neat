import Foundation
import NeatCore

/// Pulls the media and metadata, and fills `media/` and `frames/`.
///
/// Idempotent: it checks `needsRun` first, and writes `item.json` only after the
/// files are actually on disk, so a crash mid-fetch leaves a folder that the
/// next sweep re-runs rather than one that claims to be done.
public struct FetchStage: Stage {
    public let name = "fetch"
    public let version = StageVersions.fetch

    /// Two attempts, then the ledger marks it dead.
    public static let maxAttempts = 2

    /// TikTok's extraction fails intermittently — the same URL that errors with
    /// "Unable to extract universal data for rehydration" succeeds seconds
    /// later. Observed repeatedly in testing, so a few in-stage retries happen
    /// before the item burns one of its two real attempts.
    static let transientRetries = 3
    static let retryBackoff = Duration.seconds(3)

    let runner: ProcessRunner
    let preflight: ToolPreflight

    public init(
        runner: ProcessRunner = ProcessRunner(),
        preflight: ToolPreflight = ToolPreflight()
    ) {
        self.runner = runner
        self.preflight = preflight
    }

    public func run(_ item: Item, paths: NeatPaths) async throws -> Item {
        var item = item

        guard item.stages.fetch.needsRun(currentVersion: version) else { return item }

        // Threads has no yt-dlp extractor, so everything below this line — the
        // tools, the info JSON, the type detection — simply does not apply.
        if item.platform == .threads { return try await runThreads(item, paths: paths) }

        guard let ytDlp = preflight.locate(.ytDlp) else { throw StageError.toolMissing("yt-dlp") }
        guard let ffmpeg = preflight.locate(.ffmpeg) else { throw StageError.toolMissing("ffmpeg") }

        let folder = paths.itemFolder(item.id)
        let media = paths.media(item.id)
        let frames = paths.frames(item.id)
        try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        // 1. Metadata first. Cheap, and it decides everything that follows.
        let info = try await fetchInfo(ytDlp: ytDlp, url: item.url, into: folder)
        let type = TypeDetector.detect(info: info, sourceURL: URL(string: item.url) ?? URL(filePath: "/"))

        item.type = type
        item.author = info.author
        item.caption = info.caption
        item.uploadDate = info.uploadedAt

        // 2. Media and frames, which is the only part that depends on type.
        let extractor = FrameExtractor(runner: runner, ffmpeg: ffmpeg)

        switch type {
        case .video:
            let video = try await downloadVideo(ytDlp: ytDlp, url: item.url, into: media)
            try await extractAudio(ffmpeg: ffmpeg, from: video, into: media)
            _ = try await extractor.extractFromVideo(video, into: frames)

        case .slideshow:
            let slides = info.slideURLs
            if !slides.isEmpty {
                // yt-dlp handed back image URLs.
                _ = try await extractor.download(images: slides, into: frames)
            } else if let video = try? await downloadVideo(ytDlp: ytDlp, url: item.url, into: media) {
                // yt-dlp rendered the slides into an mp4 instead.
                try? await extractAudio(ffmpeg: ffmpeg, from: video, into: media)
                _ = try await extractor.extractFromSlideshowVideo(video, into: frames)
            } else {
                throw StageError.fetchFailed("photo post yielded neither slide images nor a video")
            }

        case .image:
            let urls = info.slideURLs.isEmpty
                ? (info.thumbnails ?? []).compactMap { $0.url.flatMap(URL.init(string:)) }
                : info.slideURLs
            guard !urls.isEmpty else { throw StageError.fetchFailed("no images in post") }
            _ = try await extractor.download(images: urls, into: frames)
        }

        try await writePoster(info: info, into: media)

        item.stages.fetch = .completed(v: version)
        return item
    }

    /// Retries a yt-dlp invocation through TikTok's intermittent extraction
    /// failures. Anything that still fails after this is a real failure.
    func retrying<T>(_ label: String, _ body: () async throws -> T) async throws -> T {
        var lastError: (any Error)?
        for attempt in 1...Self.transientRetries {
            do {
                return try await body()
            } catch {
                lastError = error
                guard attempt < Self.transientRetries else { break }
                Log.pipeline.notice("\(label, privacy: .public) attempt \(attempt) failed, retrying")
                try? await Task.sleep(for: Self.retryBackoff)
            }
        }
        throw lastError ?? StageError.fetchFailed(label)
    }

    // MARK: - steps

    func fetchInfo(ytDlp: String, url: String, into folder: URL) async throws -> MediaInfo {
        let result = try await retrying("info json") {
            try await runner.runChecked(ytDlp, [
                "--dump-single-json", "--no-warnings", "--no-playlist", url,
            ], timeout: .seconds(120))
        }

        // Kept verbatim next to the item: yt-dlp's schema moves, and the raw
        // payload is the only way to debug a wrong type six months from now.
        try atomicWrite(result.stdout, to: folder.appending(path: "info.json"))

        do {
            return try JSONDecoder().decode(MediaInfo.self, from: result.stdout)
        } catch {
            throw StageError.fetchFailed("could not read yt-dlp info json: \(error.localizedDescription)")
        }
    }

    func downloadVideo(ytDlp: String, url: String, into media: URL) async throws -> URL {
        let target = media.appending(path: "video.mp4")
        if FileManager.default.fileExists(atPath: target.path()) { return target }

        _ = try await retrying("video download") {
            try await runner.runChecked(ytDlp, [
                "--no-warnings", "--no-playlist",
                "-f", "bv*+ba/b",
                "--merge-output-format", "mp4",
                "-o", target.path(),
                url,
            ], timeout: .seconds(600))
        }

        guard FileManager.default.fileExists(atPath: target.path()) else {
            throw StageError.fetchFailed("yt-dlp reported success but wrote no video")
        }
        return target
    }

    func extractAudio(ffmpeg: String, from video: URL, into media: URL) async throws {
        let target = media.appending(path: "audio.m4a")
        if FileManager.default.fileExists(atPath: target.path()) { return }

        try await runner.runChecked(ffmpeg, [
            "-nostdin", "-y", "-i", video.path(),
            "-vn", "-acodec", "aac", "-b:a", "128k",
            target.path(),
        ])
    }

    func writePoster(info: MediaInfo, into media: URL) async throws {
        let target = media.appending(path: "poster.jpg")
        if FileManager.default.fileExists(atPath: target.path()) { return }

        let candidates = (info.thumbnails ?? []).compactMap { $0.url.flatMap(URL.init(string:)) }
        guard let poster = candidates.last else { return }
        if let (data, _) = try? await URLSession.shared.data(from: poster), !data.isEmpty {
            try? data.write(to: target, options: .atomic)
        }
    }
}

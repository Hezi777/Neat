import Foundation
import NeatAdapters
import NeatCore

/// Fetches one Threads post from its public embed page.
///
/// There is no yt-dlp extractor for Threads, so this is the whole acquisition
/// path. `/t/<shortcode>/embed/` is the only Threads surface that renders
/// server-side; the post page itself ships an empty SPA shell.
public struct ThreadsFetch: Sendable {
    /// Deliberately **not** a browser string. Threads serves the JS shell to
    /// anything that looks like a browser and the rendered embed to everything
    /// else, which is the inverse of the usual scraping advice.
    static let userAgent = "Neat/1.0 (+local archiver)"

    let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func post(for id: CanonicalID) async throws -> ThreadsPost {
        guard let embed = ThreadsURL.embedURL(for: id) else {
            throw StageError.fetchFailed("\(id.folderName) is not a Threads id")
        }

        var request = URLRequest(url: embed)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw StageError.fetchFailed("Threads embed returned HTTP \(http.statusCode) for \(embed.absoluteString)")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw StageError.fetchFailed("Threads embed for \(id.nativeID) was not UTF-8")
        }

        do {
            return try ThreadsEmbed.parse(html: html, source: embed.absoluteString)
        } catch let error as ThreadsEmbedError {
            // A deleted or private post answers 200 with a shell, so say that
            // rather than letting an empty folder look like a success.
            throw StageError.fetchFailed(
                "no post at \(embed.absoluteString) — deleted, private, or never existed (\(error))")
        }
    }
}

extension FetchStage {
    /// The Threads branch of `run`.
    ///
    /// Body text is the first-class channel here, not a caption: it goes to
    /// `body.txt` next to `onscreen.txt`. Attachments land in `frames/` with the
    /// same `frame-00.jpg` naming as every other type, so nothing downstream
    /// branches on where the item came from.
    func runThreads(_ item: Item, paths: NeatPaths) async throws -> Item {
        var item = item

        let post = try await ThreadsFetch().post(for: item.id)

        let frames = paths.frames(item.id)
        try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)

        // Written before the stage is marked done: a crash in between re-runs
        // the fetch, which is cheap, rather than leaving a folder that lies.
        try atomicWrite(post.text, to: paths.body(item.id))

        if !post.imageURLs.isEmpty {
            // ffmpeg is irrelevant to this path — `download` never shells out —
            // but the extractor is shared so the frame naming stays in one place.
            let extractor = FrameExtractor(runner: runner, ffmpeg: preflight.locate(.ffmpeg) ?? "")
            let written = try await extractor.download(images: post.imageURLs, into: frames)
            guard written > 0 else {
                throw StageError.fetchFailed("all \(post.imageURLs.count) Threads attachments failed to download")
            }
        }
        // No attachments means nothing was on screen. `OnscreenStage` itself
        // recognizes this case (a text-only Threads post with fetch done) and
        // skips rather than throwing on the empty `frames/`.

        // `.image` is the honest type: no speech, so transcribe skips itself.
        item.type = .image
        item.author = post.author
        item.caption = post.text.isEmpty ? nil : post.text

        item.stages.fetch = .completed(v: version)
        return item
    }
}

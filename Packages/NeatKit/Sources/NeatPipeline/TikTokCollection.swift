import Foundation
import NeatAdapters

/// Lists a collection before the ordinary per-post intake and dedupe run.
/// Uses the same Chrome session as Clipmine; no media is downloaded here.
public struct TikTokCollection: Sendable {
    let runner: ProcessRunner
    let preflight: ToolPreflight

    public init(runner: ProcessRunner = ProcessRunner(), preflight: ToolPreflight = ToolPreflight()) {
        self.runner = runner
        self.preflight = preflight
    }

    public func posts(in url: URL) async throws -> [URL] {
        guard TikTokURL.isCollection(url) else {
            throw CollectionError("This is not a TikTok collection link.")
        }
        guard let executable = preflight.locate(.ytDlp) else {
            throw CollectionError("Install yt-dlp to import TikTok collections.")
        }
        var clean = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        clean.scheme = "https"
        clean.host = "www.tiktok.com"
        clean.query = nil
        clean.fragment = nil

        let result = try await runner.run(executable, [
            "--flat-playlist", "--dump-single-json", "--skip-download",
            "--cookies-from-browser", "chrome", "--socket-timeout", "20",
            "--retries", "2", "--extractor-retries", "2", "--sleep-requests", "2",
            clean.url!.absoluteString,
        ], timeout: .seconds(900))
        guard result.succeeded else {
            throw CollectionError("Could not list this collection. Check that you can open it in Chrome while signed into TikTok, then try again.")
        }
        return try Self.parse(result.stdout)
    }

    static func parse(_ data: Data) throws -> [URL] {
        struct Listing: Decodable {
            let _type: String
            let entries: [Entry?]
        }
        struct Entry: Decodable {
            let id: String
            let url: String?
            let webpage_url: String?
        }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data),
              listing._type == "playlist" else {
            throw CollectionError("TikTok returned an unreadable collection listing. Try again later.")
        }
        guard !listing.entries.isEmpty else {
            throw CollectionError("No posts were returned. The collection may be empty or private; check it in Chrome while signed into TikTok.")
        }
        var seen = Set<String>()
        return try listing.entries.map { entry in
            guard let entry,
                  let raw = entry.webpage_url ?? entry.url,
                  let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  TikTokURL.nativeID(from: url) == entry.id else {
                throw CollectionError("TikTok returned an incomplete collection. Nothing from this listing was queued; try again later.")
            }
            guard seen.insert(entry.id).inserted else {
                throw CollectionError("TikTok repeated a page, so this collection may be truncated. Nothing from this listing was queued; try again later.")
            }
            return url
        }
    }
}

struct CollectionError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

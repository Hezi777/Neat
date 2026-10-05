import Foundation
import NeatCore

/// Threads.
///
/// Unlike TikTok there is no yt-dlp extractor for Threads, so the fetch path is
/// Neat's own — see `ThreadsFetch` in `NeatPipeline`. The adapter's job stops at
/// identity, and that never needs the network: a post URL carries its shortcode.
public struct ThreadsAdapter: SourceAdapter {
    public let platform: Platform = .threads

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        ThreadsURL.isThreads(url)
    }

    public func canonicalID(for url: URL) async throws -> CanonicalID {
        guard canHandle(url) else {
            throw AdapterError.unrecognizedURL(url.absoluteString)
        }
        guard let id = ThreadsURL.canonicalID(from: url) else {
            throw AdapterError.unrecognizedURL(
                "\(url.absoluteString) is a Threads link but carries no post shortcode")
        }
        return id
    }
}

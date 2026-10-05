import Foundation
import NeatCore

/// TikTok post identity and share-link resolution.
public struct TikTokAdapter: SourceAdapter {
    public let platform: Platform = .tiktok
    let resolver: RedirectResolver

    public init(resolver: RedirectResolver = HTTPRedirectResolver()) {
        self.resolver = resolver
    }

    public func canHandle(_ url: URL) -> Bool {
        TikTokURL.isTikTok(url)
    }

    public func resolvedURL(for url: URL) async throws -> URL {
        guard TikTokURL.isShortLink(url) else { return url }
        return try await resolver.resolve(url)
    }

    /// Normalizes a URL down to its canonical ID, resolving short links over the
    /// network only when the ID cannot be read off the URL directly.
    public func canonicalID(for url: URL) async throws -> CanonicalID {
        guard canHandle(url) else {
            throw AdapterError.unrecognizedURL(url.absoluteString)
        }

        // Cheap path first: no network unless the URL actually hides its ID.
        if let id = TikTokURL.canonicalID(from: url) { return id }

        guard TikTokURL.isShortLink(url) else {
            throw AdapterError.unrecognizedURL(url.absoluteString)
        }

        let resolved = try await resolvedURL(for: url)
        guard let id = TikTokURL.canonicalID(from: resolved) else {
            throw AdapterError.unrecognizedURL(
                "\(url.absoluteString) resolved to \(resolved.absoluteString), which carries no video id")
        }
        return id
    }
}

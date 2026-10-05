import Foundation
import NeatCore

/// Pure, synchronous TikTok URL parsing. No network, no side effects.
///
/// This is where dedup actually breaks, so it is kept separate from everything
/// that touches the network and is tested on its own.
public enum TikTokURL {
    /// Hosts that hand back a redirect rather than a video ID.
    static let shortHosts: Set<String> = ["vm.tiktok.com", "vt.tiktok.com"]

    /// Path segments that precede a numeric video ID.
    ///
    /// `photo` is the slideshow form and matters as much as `video` — dropping
    /// it would silently lose every photo-mode post.
    static let idPrefixes: Set<String> = ["video", "photo", "v"]

    /// Lowercased host with any `www.` stripped.
    public static func normalizedHost(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public static func isTikTok(_ url: URL) -> Bool {
        guard let host = normalizedHost(url) else { return false }
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
    }

    /// Whether the URL has to be resolved over the network before it can be keyed.
    public static func isShortLink(_ url: URL) -> Bool {
        guard let host = normalizedHost(url) else { return false }
        if shortHosts.contains(host) { return true }
        // www.tiktok.com/t/ZTabcdef/ is also a redirect stub.
        return segments(url).first == "t"
    }

    public static func isCollection(_ url: URL) -> Bool {
        guard isTikTok(url) else { return false }
        let comps = segments(url)
        return comps.count == 3 && comps[0].hasPrefix("@")
            && comps[1].lowercased() == "collection"
    }

    static func segments(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }

    static func isNumericID(_ s: String) -> Bool {
        !s.isEmpty && s.count >= 8 && s.allSatisfy(\.isNumber)
    }

    /// Extracts the numeric video ID, ignoring query parameters, fragments,
    /// trailing slashes and the `@user` segment entirely.
    ///
    /// Returns nil for short links — those must be resolved first.
    public static func nativeID(from url: URL) -> String? {
        guard isTikTok(url), !isCollection(url) else { return nil }

        let comps = segments(url)

        // /@user/video/123, /@user/photo/123, /video/123, /v/123.html
        for (i, segment) in comps.enumerated() where idPrefixes.contains(segment.lowercased()) {
            guard i + 1 < comps.count else { continue }
            var candidate = comps[i + 1]
            if let dot = candidate.firstIndex(of: ".") { candidate = String(candidate[..<dot]) }
            if isNumericID(candidate) { return candidate }
        }

        // Bare trailing numeric id, e.g. tiktok.com/12345678901234567
        if let last = comps.last, isNumericID(last) { return last }

        return nil
    }

    /// The canonical ID for a URL that needs no network resolution.
    public static func canonicalID(from url: URL) -> CanonicalID? {
        nativeID(from: url).map { CanonicalID(platform: .tiktok, nativeID: $0) }
    }
}

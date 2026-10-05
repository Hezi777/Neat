import Foundation
import NeatCore

/// Pure, synchronous Threads URL parsing. No network, no side effects.
///
/// Mirrors `TikTokURL`: this is where dedup actually breaks, so it is kept away
/// from anything that touches the network and tested on its own.
public enum ThreadsURL {
    /// Threads serves the same content from both apex domains, and links in the
    /// wild carry either. They must key to one ID.
    static let hosts: Set<String> = ["threads.net", "threads.com"]

    /// Path segments that precede a post shortcode. `t` is the short form the
    /// share sheet produces; it is not a redirect stub, it already carries the
    /// shortcode, so unlike TikTok's `/t/` nothing has to be resolved.
    static let idPrefixes: Set<String> = ["post", "t"]

    /// Base64url alphabet — Threads shortcodes are Instagram media codes.
    static let shortcodeCharacters = Set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-")

    /// Lowercased host with any `www.` stripped.
    public static func normalizedHost(_ url: URL) -> String? {
        guard let host = url.host()?.lowercased() else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    public static func isThreads(_ url: URL) -> Bool {
        guard let host = normalizedHost(url) else { return false }
        // Suffix, not `contains`: `threads.net.evil.example` must not match.
        return hosts.contains(host) || hosts.contains(where: { host.hasSuffix(".\($0)") })
    }

    static func segments(_ url: URL) -> [String] {
        url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    }

    /// Short enough to be a real code, long enough not to swallow a route name
    /// like `/@user/replies`.
    static func isShortcode(_ s: String) -> Bool {
        s.count >= 5 && s.allSatisfy { shortcodeCharacters.contains($0) }
    }

    /// Extracts the post shortcode, ignoring query parameters, fragments,
    /// trailing slashes and the `@user` segment entirely.
    ///
    /// The shortcode is the canonical native ID: the same post reached through
    /// `.net`, `.com`, `/t/` or a tracking link keys to one folder.
    public static func nativeID(from url: URL) -> String? {
        guard isThreads(url) else { return nil }

        let comps = segments(url)
        for (i, segment) in comps.enumerated() where idPrefixes.contains(segment.lowercased()) {
            guard i + 1 < comps.count else { continue }
            let candidate = comps[i + 1]
            if isShortcode(candidate) { return candidate }
        }
        return nil
    }

    public static func canonicalID(from url: URL) -> CanonicalID? {
        nativeID(from: url).map { CanonicalID(platform: .threads, nativeID: $0) }
    }

    /// The public embed page for a post.
    ///
    /// Built from the shortcode alone — the `@user` segment is decorative and
    /// the server ignores it, so the canonical ID is enough and a stored URL
    /// with a stale username still resolves.
    public static func embedURL(shortcode: String) -> URL? {
        URL(string: "https://www.threads.com/t/\(shortcode)/embed/")
    }

    public static func embedURL(for id: CanonicalID) -> URL? {
        guard id.platform == .threads else { return nil }
        return embedURL(shortcode: id.nativeID)
    }
}

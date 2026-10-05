import Foundation

/// One URL normalizer, used for both the resource id and the Notion dedupe key.
///
/// It has to be one function: if the id and the dedupe key disagree by so much
/// as a trailing slash, the same tool lands in Notion twice. Notion stores
/// whatever was originally pasted, so the comparison always runs both sides
/// through here rather than trusting either string.
public enum ResourceURL {
    /// Analytics and share-tracking parameters. Dropping them is safe — no site
    /// serves different content for them — and keeping them splits one resource
    /// into several.
    static let trackingParams: Set<String> = ["fbclid", "igshid", "si", "ref", "ref_src"]

    /// Lowercased host without `www.`, no fragment, no tracking params, no
    /// trailing slash. Returns nil for anything that is not a usable http(s) URL.
    ///
    /// The path keeps its case: hosts are case-insensitive, paths are not, and
    /// lowercasing a GitHub repo path would break the link.
    public static func normalize(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // Models routinely emit bare domains. Treating `github.com/x` and
        // `https://github.com/x` as different resources would be a dedupe bug.
        // Only a string with no scheme at all gets one — `mailto:` has a scheme
        // and must be rejected below, not turned into a web address.
        if text.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*:", options: .regularExpression) == nil {
            text = "https://" + text
        }

        guard var parts = URLComponents(string: text) else { return nil }
        let scheme = (parts.scheme ?? "").lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        guard var host = parts.host?.lowercased(), !host.isEmpty, host.contains(".") else { return nil }

        if host.hasPrefix("www.") { host.removeFirst(4) }
        parts.scheme = scheme
        parts.host = host
        parts.fragment = nil
        parts.user = nil
        parts.password = nil

        if let items = parts.queryItems {
            let kept = items.filter { !isTracking($0.name) }
            parts.queryItems = kept.isEmpty ? nil : kept
        }

        // Every trailing slash goes, the root one included: `example.com` and
        // `example.com/` are the same page and must produce the same key.
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        parts.percentEncodedPath = path

        return parts.string
    }

    /// True when two URLs point at the same resource once normalized.
    public static func sameResource(_ a: String?, _ b: String?) -> Bool {
        guard let a = a.flatMap(normalize)?.lowercased(),
              let b = b.flatMap(normalize)?.lowercased()
        else { return false }
        return a == b
    }

    /// `https://github.com/a/b` → `github.com/a/b`. Notion's `url` filter has no
    /// equality that survives a scheme difference, so the query asks for
    /// `contains` on this and the real comparison happens locally.
    public static func schemeless(_ url: String) -> String? {
        guard let normalized = normalize(url) else { return nil }
        guard let range = normalized.range(of: "://") else { return normalized }
        return String(normalized[range.upperBound...])
    }

    static func isTracking(_ name: String) -> Bool {
        let name = name.lowercased()
        return name.hasPrefix("utm_") || trackingParams.contains(name)
    }
}

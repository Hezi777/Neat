import Foundation

/// Pulls links out of whatever got pasted.
///
/// People paste one link, a column of links, or a wall of text with links in it.
/// All three have to work, so this uses the system link detector rather than
/// splitting on newlines.
public enum PasteParser {
    public static func extractURLs(from text: String) -> [URL] {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return [] }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        var seen = Set<String>()
        var urls: [URL] = []

        detector.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let url = match?.url else { return }
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else { return }
            // Same link pasted twice is one item, and paste order is preserved.
            if seen.insert(url.absoluteString).inserted { urls.append(url) }
        }

        return urls
    }
}

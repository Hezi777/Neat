import Foundation
import NeatCore

public enum ThreadsEmbedError: Error, Sendable, Equatable {
    /// The embed page rendered, but carried no post — deleted, private, or a
    /// shortcode that never existed. Threads answers all three with HTTP 200
    /// and an empty shell, so the only honest signal is the missing content.
    case postUnavailable(String)
}

/// One Threads post, as far as the public embed page reveals it.
public struct ThreadsPost: Sendable, Equatable {
    /// The post body. Attachments are the payload, but this is the caption.
    public let text: String
    /// Every attachment image, in post order. Video attachments contribute
    /// nothing here — the embed page carries the mp4, not a still.
    public let imageURLs: [URL]
    public let author: String?

    public init(text: String, imageURLs: [URL], author: String? = nil) {
        self.text = text
        self.imageURLs = imageURLs
        self.author = author
    }
}

/// Parses the public embed page at `/t/<shortcode>/embed/`.
///
/// That page is the one Threads surface that is server-rendered to an ordinary
/// client: the post page itself ships an empty SPA shell to any browser user
/// agent. It is plain HTML with no JSON payload, so this reads the handful of
/// class names the embed markup is built from rather than decoding a blob.
///
/// Pure and synchronous, so it can be tested against saved HTML.
public enum ThreadsEmbed {
    static let bodyMarker = "BodyTextContainer\">"
    static let authorMarker = "class=\"HeaderLink\">"
    /// The two containers the embed wraps attachments in — one per carousel
    /// item, or one for a lone attachment. The author avatar lives in
    /// `AvatarContainer` instead, which is what keeps it out of `frames/`.
    static let mediaMarkers = ["class=\"MediaScrollImageContainer\"", "class=\"SingleInnerMediaContainer\""]

    public static func parse(html: String, source: String = "embed page") throws -> ThreadsPost {
        let text = bodyText(in: html)
        let images = imageURLs(in: html)

        // A live post always has one or the other. Neither means the page is a
        // shell, and reporting that beats writing an empty folder.
        guard !text.isEmpty || !images.isEmpty else {
            throw ThreadsEmbedError.postUnavailable(source)
        }
        return ThreadsPost(text: text, imageURLs: images, author: author(in: html))
    }

    // MARK: - pieces

    /// The body runs from `BodyTextContainer">` to the first `<div` after it —
    /// the body is built only from `<span>` and `<a>`, and every sibling that
    /// follows it (media, a quoted post, the date) opens with a div.
    static func bodyText(in html: String) -> String {
        guard let marker = html.range(of: bodyMarker) else { return "" }
        let rest = html[marker.upperBound...]
        let end = rest.range(of: "<div")?.lowerBound ?? rest.endIndex
        return decodeEntities(strippingTags(String(rest[..<end])))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func author(in html: String) -> String? {
        guard let marker = html.range(of: authorMarker) else { return nil }
        let rest = html[marker.upperBound...]
        let end = rest.range(of: "</a>")?.lowerBound ?? rest.endIndex
        let name = decodeEntities(strippingTags(String(rest[..<end])))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// Every attachment image, in post order.
    ///
    /// Each media container holds exactly one element, so the search for an
    /// `<img>` is bounded by the next container — a video attachment must not
    /// borrow the image of the slide after it.
    static func imageURLs(in html: String) -> [URL] {
        let starts = mediaMarkers
            .flatMap { marker in html.ranges(of: marker).map(\.upperBound) }
            .sorted()
        guard !starts.isEmpty else { return [] }

        var urls: [URL] = []
        var seen = Set<String>()

        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : html.endIndex
            let slice = String(html[start..<end])
            guard let raw = firstImageSource(in: slice) else { continue }
            let decoded = decodeEntities(raw)
            guard seen.insert(decoded).inserted, let url = URL(string: decoded) else { continue }
            urls.append(url)
        }
        return urls
    }

    static func firstImageSource(in slice: String) -> String? {
        let img = /<img\b[^>]*?\bsrc="([^"]+)"/
        guard let match = slice.firstMatch(of: img) else { return nil }
        return String(match.1)
    }

    // MARK: - text

    static func strippingTags(_ html: String) -> String {
        var out = ""
        var inTag = false
        for char in html {
            switch char {
            case "<": inTag = true
            case ">": inTag = false
            default: if !inTag { out.append(char) }
            }
        }
        return out
    }

    /// Minimal HTML entity decoding.
    ///
    /// Threads escapes aggressively — `@` arrives as `&#064;` and braces as
    /// `&#123;` — so the numeric forms matter as much as the named ones, and
    /// `NSAttributedString`'s HTML importer is not an option outside AppKit.
    static func decodeEntities(_ string: String) -> String {
        guard string.contains("&") else { return string }

        let named: [Substring: Character] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        ]

        var out = ""
        var rest = Substring(string)

        while let amp = rest.firstIndex(of: "&") {
            out += rest[..<amp]
            let after = rest.index(after: amp)
            // An entity is short; a bare `&` in prose must not eat the rest.
            let window = rest[after...].prefix(10)
            guard let semi = window.firstIndex(of: ";") else {
                out.append("&")
                rest = rest[after...]
                continue
            }

            let body = rest[after..<semi]
            if let char = named[body] {
                out.append(char)
            } else if body.hasPrefix("#"),
                      let scalar = numericScalar(body.dropFirst()) {
                out.append(Character(scalar))
            } else {
                out += rest[amp...semi]
            }
            rest = rest[rest.index(after: semi)...]
        }

        return out + rest
    }

    static func numericScalar(_ digits: Substring) -> Unicode.Scalar? {
        let isHex = digits.first == "x" || digits.first == "X"
        let value = UInt32(isHex ? digits.dropFirst() : digits, radix: isHex ? 16 : 10)
        return value.flatMap(Unicode.Scalar.init)
    }
}

import Foundation
import NeatCore

/// The subset of `yt-dlp`'s info JSON that Neat actually uses.
///
/// Decoded leniently: yt-dlp's schema shifts between releases, and a new key we
/// do not know about must never fail a fetch.
public struct MediaInfo: Decodable, Sendable {
    public let id: String?
    public let title: String?
    public let description: String?
    public let uploader: String?
    public let channel: String?
    public let uploadDate: String?
    public let timestamp: Double?
    public let duration: Double?
    public let ext: String?
    public let vcodec: String?
    public let acodec: String?
    /// Present on photo-mode posts in some yt-dlp releases.
    public let images: [ImageEntry]?
    public let thumbnails: [ImageEntry]?
    public let formats: [Format]?

    public struct ImageEntry: Decodable, Sendable {
        public let url: String?
        public let id: String?
        public let width: Int?
        public let height: Int?
    }

    public struct Format: Decodable, Sendable {
        public let ext: String?
        public let vcodec: String?
        public let acodec: String?
        public let url: String?
    }

    enum CodingKeys: String, CodingKey {
        case id, title, description, uploader, channel, timestamp, duration, ext
        case vcodec, acodec, images, thumbnails, formats
        case uploadDate = "upload_date"
    }

    /// `20260904` → a Date, which is how yt-dlp reports upload dates.
    public var uploadedAt: Date? {
        if let timestamp { return Date(timeIntervalSince1970: timestamp).neatTruncated }
        guard let uploadDate, uploadDate.count == 8 else { return nil }
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "UTC")
        return f.date(from: uploadDate)
    }

    public var author: String? { uploader ?? channel }

    /// Caption. yt-dlp puts the post text in `description`, falling back to `title`.
    public var caption: String? {
        let text = description ?? title
        return text?.isEmpty == false ? text : nil
    }

    /// Image URLs for a photo-mode post, in slide order.
    ///
    /// `images` is the reliable signal when present. `thumbnails` is not — every
    /// video has those — so it is only consulted when the caller already knows
    /// this is a photo post.
    public var slideURLs: [URL] {
        (images ?? []).compactMap { $0.url.flatMap(URL.init(string:)) }
    }

    public var hasVideoStream: Bool {
        if let vcodec, vcodec != "none" { return true }
        return (formats ?? []).contains { ($0.vcodec ?? "none") != "none" }
    }
}

/// Decides what kind of item this is from what actually came back.
///
/// The URL shape is only a tie-breaker. yt-dlp's photo-mode handling changes
/// between releases — it may return image URLs, or it may render the slides into
/// an mp4 — so both shapes have to be recognised from the payload first.
public enum TypeDetector {
    public static func detect(info: MediaInfo, sourceURL: URL) -> ItemType {
        // Strongest signal: the payload literally carries slide images.
        if !info.slideURLs.isEmpty { return .slideshow }

        let looksLikePhotoPost = sourceURL.pathComponents.contains("photo")

        // yt-dlp rendered the slides into a video. Still a slideshow: frames are
        // extracted per slide transition, not by scene score.
        if looksLikePhotoPost && info.hasVideoStream { return .slideshow }

        // A photo post with neither images nor a video stream: still a slideshow,
        // and the fetch stage falls back to scraping image URLs from the JSON.
        if looksLikePhotoPost { return .slideshow }

        if info.hasVideoStream { return .video }

        return .image
    }
}

import Foundation
import NeatCore
import Testing

@testable import NeatAdapters

@Suite("TikTok URL normalization")
struct TikTokURLTests {
    static let id = "7381234567890"

    /// Every one of these is the same post and must key to the same ID.
    @Test(
        "keys the canonical URL shapes",
        arguments: [
            "https://www.tiktok.com/@user/video/7381234567890",
            "https://tiktok.com/@user/video/7381234567890",
            "https://www.tiktok.com/@user/video/7381234567890/",
            "https://m.tiktok.com/v/7381234567890.html",
            "https://www.tiktok.com/video/7381234567890",
            "http://www.tiktok.com/@user/video/7381234567890",
            "https://WWW.TikTok.com/@User/Video/7381234567890",
        ]
    )
    func keysAllShapes(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(TikTokURL.nativeID(from: url) == Self.id)
    }

    /// Tracking params are the most common way a duplicate sneaks in.
    @Test(
        "strips query parameters and fragments",
        arguments: [
            "https://www.tiktok.com/@user/video/7381234567890?is_from_webapp=1&sender_device=pc",
            "https://www.tiktok.com/@user/video/7381234567890?_r=1&_t=8abcdef",
            "https://www.tiktok.com/@user/video/7381234567890#comments",
            "https://www.tiktok.com/@user/video/7381234567890/?lang=en",
        ]
    )
    func stripsNoise(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(TikTokURL.nativeID(from: url) == Self.id)
    }

    @Test("photo-mode posts key exactly like videos")
    func photoMode() throws {
        let url = try #require(URL(string: "https://www.tiktok.com/@user/photo/7381234567890"))
        #expect(TikTokURL.nativeID(from: url) == Self.id)
    }

    @Test("every shape collapses to one canonical id")
    func allShapesAgree() throws {
        let shapes = [
            "https://www.tiktok.com/@user/video/7381234567890",
            "https://www.tiktok.com/@other/photo/7381234567890",
            "https://m.tiktok.com/v/7381234567890.html?_t=1",
        ]
        let ids = try shapes.map { raw -> CanonicalID in
            let url = try #require(URL(string: raw))
            return try #require(TikTokURL.canonicalID(from: url))
        }
        #expect(Set(ids).count == 1)
        #expect(ids[0].folderName == "tiktok-7381234567890")
    }

    @Test(
        "recognises short links that need resolving",
        arguments: [
            "https://vm.tiktok.com/ZMabcdef/",
            "https://vt.tiktok.com/ZSabcdef/",
            "https://www.tiktok.com/t/ZTabcdef/",
        ]
    )
    func detectsShortLinks(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(TikTokURL.isShortLink(url))
        // A short link carries no id, so it must not be keyed without resolving.
        #expect(TikTokURL.nativeID(from: url) == nil)
    }

    @Test("a full URL is not treated as a short link")
    func fullURLIsNotShort() throws {
        let url = try #require(URL(string: "https://www.tiktok.com/@user/video/7381234567890"))
        #expect(!TikTokURL.isShortLink(url))
    }

    @Test(
        "refuses non-TikTok and unkeyable URLs",
        arguments: [
            "https://nottiktok.com/@user/video/7381234567890",
            "https://tiktok.com.evil.example/@user/video/7381234567890",
            "https://www.tiktok.com/@user",
            "https://www.tiktok.com/",
            "https://www.instagram.com/p/abc123/",
        ]
    )
    func refusesGarbage(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(TikTokURL.canonicalID(from: url) == nil)
    }

    @Test("a too-short numeric segment is not mistaken for an id")
    func rejectsShortNumbers() throws {
        let url = try #require(URL(string: "https://www.tiktok.com/@user/video/123"))
        #expect(TikTokURL.nativeID(from: url) == nil)
    }

    @Test("collection IDs are never video IDs", arguments: [
        "https://www.tiktok.com/@hen/collection/AI-7599982720722815752",
        "https://www.tiktok.com/@hen/collection/7599982720722815752",
    ])
    func collectionIsNotPost(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(TikTokURL.nativeID(from: url) == nil)
    }
}

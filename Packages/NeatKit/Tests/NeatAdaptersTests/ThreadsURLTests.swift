import Foundation
import NeatCore
import Testing

@testable import NeatAdapters

@Suite("Threads URL normalization")
struct ThreadsURLTests {
    static let code = "Dcy_A8pGo-m"

    /// Every one of these is the same post and must key to the same ID.
    /// `.com` matters as much as `.net`: Threads now redirects to it, so both
    /// turn up in a paste.
    @Test(
        "keys the canonical URL shapes",
        arguments: [
            "https://www.threads.net/@zuck/post/Dcy_A8pGo-m",
            "https://www.threads.com/@zuck/post/Dcy_A8pGo-m",
            "https://threads.net/@zuck/post/Dcy_A8pGo-m",
            "https://www.threads.com/@zuck/post/Dcy_A8pGo-m/",
            "http://www.threads.net/@zuck/post/Dcy_A8pGo-m",
            "https://WWW.Threads.NET/@Zuck/post/Dcy_A8pGo-m",
            "https://www.threads.com/t/Dcy_A8pGo-m",
            "https://www.threads.com/t/Dcy_A8pGo-m/",
        ]
    )
    func keysAllShapes(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(ThreadsURL.nativeID(from: url) == Self.code)
    }

    /// Tracking params are the most common way a duplicate sneaks in.
    @Test(
        "strips query parameters and fragments",
        arguments: [
            "https://www.threads.net/@zuck/post/Dcy_A8pGo-m?igshid=NTc4MTIwNjQ2YQ==",
            "https://www.threads.com/@zuck/post/Dcy_A8pGo-m?xmt=AQG0DTR7H2MAHsHYN3ydrHwR",
            "https://www.threads.com/@zuck/post/Dcy_A8pGo-m#comments",
            "https://www.threads.com/@zuck/post/Dcy_A8pGo-m/?hl=en",
        ]
    )
    func stripsNoise(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(ThreadsURL.nativeID(from: url) == Self.code)
    }

    @Test("a tracking link and a bare link are one item")
    func trackingLinkDedups() throws {
        let bare = try #require(URL(string: "https://www.threads.net/@zuck/post/Dcy_A8pGo-m"))
        let tracked = try #require(URL(string: "https://www.threads.com/@zuck/post/Dcy_A8pGo-m/?igshid=abc&xmt=def#top"))

        let ids = try [bare, tracked].map { try #require(ThreadsURL.canonicalID(from: $0)) }
        #expect(Set(ids).count == 1)
        #expect(ids[0].folderName == "threads-Dcy_A8pGo-m")
    }

    @Test("shortcodes keep their base64url punctuation")
    func keepsPunctuation() throws {
        let url = try #require(URL(string: "https://www.threads.net/@user/post/C2isac0P7c7"))
        #expect(ThreadsURL.nativeID(from: url) == "C2isac0P7c7")
    }

    @Test(
        "refuses look-alike hosts and URLs with no shortcode",
        arguments: [
            "https://threads.net.evil.example/@zuck/post/Dcy_A8pGo-m",
            "https://notthreads.net/@zuck/post/Dcy_A8pGo-m",
            "https://threads.com.evil.example/@zuck/post/Dcy_A8pGo-m",
            "https://www.threads.net/@zuck/post/",
            "https://www.threads.net/@zuck/post",
            "https://www.threads.net/@zuck",
            "https://www.threads.net/",
            "https://www.tiktok.com/@user/video/7381234567890",
        ]
    )
    func refusesGarbage(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(ThreadsURL.canonicalID(from: url) == nil)
    }

    @Test("a subdomain of threads.net is still Threads")
    func acceptsSubdomain() throws {
        let url = try #require(URL(string: "https://m.threads.net/@zuck/post/Dcy_A8pGo-m"))
        #expect(ThreadsURL.isThreads(url))
        #expect(ThreadsURL.nativeID(from: url) == Self.code)
    }

    /// The username segment is decorative — the server ignores it — so the
    /// embed URL is built from the ID alone and a renamed account still works.
    @Test("builds the embed URL from the shortcode alone")
    func embedURL() throws {
        let id = CanonicalID(platform: .threads, nativeID: Self.code)
        let embed = try #require(ThreadsURL.embedURL(for: id))
        #expect(embed.absoluteString == "https://www.threads.com/t/Dcy_A8pGo-m/embed/")
        #expect(ThreadsURL.embedURL(for: CanonicalID(platform: .tiktok, nativeID: "123")) == nil)
    }
}

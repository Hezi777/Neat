import Foundation
import NeatCore
import Testing

@testable import NeatAdapters

/// Stands in for the network so short-link handling is testable offline.
struct StubResolver: RedirectResolver {
    let destinations: [String: String]
    func resolve(_ url: URL) async throws -> URL {
        guard let to = destinations[url.absoluteString], let dest = URL(string: to) else {
            throw AdapterError.redirectFailed(url.absoluteString)
        }
        return dest
    }
}

@Suite("Short link resolution")
struct ShortLinkTests {
    static let long = "https://www.tiktok.com/@user/video/7381234567890?is_from_webapp=1"

    @Test("resolves a short link and strips the destination's tracking params")
    func resolvesShortLink() async throws {
        let adapter = TikTokAdapter(resolver: StubResolver(
            destinations: ["https://vm.tiktok.com/ZMabcdef/": Self.long]))
        let url = try #require(URL(string: "https://vm.tiktok.com/ZMabcdef/"))

        let id = try await adapter.canonicalID(for: url)
        #expect(id.folderName == "tiktok-7381234567890")
    }

    @Test("a short link and the long link it points at are the same item")
    func shortAndLongAgree() async throws {
        let adapter = TikTokAdapter(resolver: StubResolver(
            destinations: ["https://vm.tiktok.com/ZMabcdef/": Self.long]))

        let short = try await adapter.canonicalID(for: #require(URL(string: "https://vm.tiktok.com/ZMabcdef/")))
        let long = try await adapter.canonicalID(for: #require(URL(string: Self.long)))
        #expect(short == long)
    }

    @Test("a full URL never hits the network")
    func fullURLSkipsResolver() async throws {
        // A resolver that would fail if consulted.
        let adapter = TikTokAdapter(resolver: StubResolver(destinations: [:]))
        let id = try await adapter.canonicalID(for: #require(URL(string: Self.long)))
        #expect(id.nativeID == "7381234567890")
    }

    @Test("a short link that resolves to something unkeyable throws")
    func badDestination() async throws {
        let adapter = TikTokAdapter(resolver: StubResolver(
            destinations: ["https://vm.tiktok.com/ZMdead/": "https://www.tiktok.com/"]))
        let url = try #require(URL(string: "https://vm.tiktok.com/ZMdead/"))

        await #expect(throws: AdapterError.self) {
            _ = try await adapter.canonicalID(for: url)
        }
    }
}

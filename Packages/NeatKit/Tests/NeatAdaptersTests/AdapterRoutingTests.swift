import Foundation
import NeatCore
import Testing

@testable import NeatAdapters

@Suite("Adapter routing")
struct AdapterRoutingTests {
    let tiktok = TikTokAdapter()
    let threads = ThreadsAdapter()

    @Test(
        "TikTok claims its own URL shapes",
        arguments: [
            "https://www.tiktok.com/@user/video/7381234567890",
            "https://tiktok.com/video/7381234567890",
            "https://vm.tiktok.com/ZMabcdef/",
            "https://m.tiktok.com/v/7381234567890.html",
        ]
    )
    func claimsTikTok(raw: String) throws {
        let url = try #require(URL(string: raw))
        #expect(tiktok.canHandle(url))
        #expect(!threads.canHandle(url))
    }

    @Test("TikTok does not claim look-alike hosts")
    func rejectsLookalikes() throws {
        let url = try #require(URL(string: "https://nottiktok.com/@user/video/1"))
        #expect(!tiktok.canHandle(url))
    }

    @Test(
        "Threads claims its own URL shapes",
        arguments: [
            "https://www.threads.net/@user/post/C2isac0P7c7",
            "https://www.threads.com/@user/post/C2isac0P7c7",
            "https://www.threads.com/t/C2isac0P7c7",
        ]
    )
    func claimsThreads(raw: String) async throws {
        let url = try #require(URL(string: raw))
        #expect(threads.canHandle(url))
        #expect(!tiktok.canHandle(url))

        // A full post URL carries its shortcode, so identity costs no network.
        let id = try await threads.canonicalID(for: url)
        #expect(id.folderName == "threads-C2isac0P7c7")
    }

    @Test("Threads refuses a link with no post in it")
    func threadsRejectsProfileLinks() async throws {
        let url = try #require(URL(string: "https://www.threads.net/@user"))
        #expect(threads.canHandle(url))

        await #expect(throws: AdapterError.self) {
            _ = try await threads.canonicalID(for: url)
        }
    }
}

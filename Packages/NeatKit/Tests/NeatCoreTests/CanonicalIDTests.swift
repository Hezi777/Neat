import Foundation
import Testing

@testable import NeatCore

@Suite("CanonicalID")
struct CanonicalIDTests {
    @Test("folder name is platform-native")
    func folderName() {
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567890")
        #expect(id.folderName == "tiktok-7381234567890")
    }

    @Test("round-trips through its folder name")
    func roundTrip() throws {
        let id = CanonicalID(platform: .tiktok, nativeID: "7381234567890")
        let parsed = try #require(CanonicalID(folderName: id.folderName))
        #expect(parsed == id)
    }

    @Test("rejects malformed folder names", arguments: ["", "tiktok", "tiktok-", "nope-123"])
    func rejectsGarbage(name: String) {
        #expect(CanonicalID(folderName: name) == nil)
    }

    @Test("keeps dashes in the native id")
    func nativeIDWithDashes() throws {
        let id = CanonicalID(platform: .threads, nativeID: "C8x-abc")
        let parsed = try #require(CanonicalID(folderName: id.folderName))
        #expect(parsed.nativeID == "C8x-abc")
    }
}

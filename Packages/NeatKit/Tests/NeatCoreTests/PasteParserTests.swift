import Foundation
import Testing

@testable import NeatCore

@Suite("Paste parsing")
struct PasteParserTests {
    @Test("pulls links out of a pasted column")
    func multipleLines() {
        let text = """
        https://www.tiktok.com/@a/video/7381234567890
        https://www.tiktok.com/@b/video/7381234567891

        https://www.tiktok.com/@c/video/7381234567892
        """
        #expect(PasteParser.extractURLs(from: text).count == 3)
    }

    @Test("finds links embedded in prose")
    func embeddedInText() {
        let text = "check this https://www.tiktok.com/@a/video/7381234567890 it's good"
        let urls = PasteParser.extractURLs(from: text)
        #expect(urls.count == 1)
        #expect(urls[0].absoluteString.hasSuffix("7381234567890"))
    }

    @Test("keeps paste order")
    func preservesOrder() {
        let text = """
        https://www.tiktok.com/@a/video/7381234567891
        https://www.tiktok.com/@a/video/7381234567890
        """
        let urls = PasteParser.extractURLs(from: text)
        #expect(urls[0].absoluteString.hasSuffix("891"))
        #expect(urls[1].absoluteString.hasSuffix("890"))
    }

    @Test("the identical link twice is one link")
    func dedupesIdentical() {
        let one = "https://www.tiktok.com/@a/video/7381234567890"
        #expect(PasteParser.extractURLs(from: "\(one)\n\(one)").count == 1)
    }

    @Test("ignores non-http schemes and plain text")
    func ignoresJunk() {
        let text = "mailto:someone@example.com\njust some words\nftp://example.com/x"
        #expect(PasteParser.extractURLs(from: text).isEmpty)
    }

    @Test("empty text yields nothing")
    func empty() {
        #expect(PasteParser.extractURLs(from: "").isEmpty)
    }
}

@Suite("Paste summary")
struct PasteSummaryTests {
    func entry(_ d: Disposition) -> IntakeEntry {
        IntakeEntry(raw: "x", id: CanonicalID(platform: .tiktok, nativeID: "7381234567890"), disposition: d)
    }

    @Test("renders the headline line")
    func headline() {
        var entries = [IntakeEntry]()
        entries += (0..<42).map { _ in entry(.new) }
        entries += (0..<58).map { _ in entry(.alreadyHave) }
        entries += (0..<6).map { _ in entry(.unavailable) }

        let s = PasteSummary(entries: entries)
        #expect(s.line == "42 new, 58 already have, 6 unavailable")
        #expect(s.total == 106)
    }

    @Test("the three headline counts show even at zero")
    func zeroesStillShow() {
        #expect(PasteSummary(entries: []).line == "0 new, 0 already have, 0 unavailable")
    }

    @Test("skipped and junk are reported rather than silently dropped")
    func reportsExtras() {
        let s = PasteSummary(entries: [
            entry(.new), entry(.skipped),
            IntakeEntry(raw: "nope", id: nil, disposition: .invalid("not a supported link")),
        ])
        #expect(s.line == "1 new, 0 already have, 0 unavailable, 1 skipped, 1 could not import")
    }
}

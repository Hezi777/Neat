import Foundation
import Testing

@testable import NeatCore

@Suite("URL normalization")
struct ResourceURLTests {
    func norm(_ s: String) -> String? { ResourceURL.normalize(s) }

    @Test("lowercases the host and drops www")
    func host() {
        #expect(norm("https://WWW.GitHub.com/a/b") == "https://github.com/a/b")
        #expect(norm("https://www.example.com") == "https://example.com")
    }

    @Test("keeps path case — paths are case-sensitive and lowercasing breaks the link")
    func pathCase() {
        #expect(norm("https://github.com/Anthropics/Claude-Code") == "https://github.com/Anthropics/Claude-Code")
    }

    @Test("drops the fragment")
    func fragment() {
        #expect(norm("https://example.com/docs#install") == "https://example.com/docs")
        #expect(norm("https://example.com/#") == "https://example.com")
    }

    @Test("strips tracking params and keeps real ones")
    func tracking() {
        #expect(norm("https://example.com/x?utm_source=tiktok&utm_medium=bio") == "https://example.com/x")
        #expect(norm("https://example.com/x?fbclid=1&igshid=2&si=3&ref=4&ref_src=5") == "https://example.com/x")
        #expect(norm("https://example.com/x?id=7&utm_campaign=z") == "https://example.com/x?id=7")
        #expect(norm("https://youtu.be/abc?si=xyz&t=30") == "https://youtu.be/abc?t=30")
    }

    @Test("tracking param matching is case-insensitive")
    func trackingCase() {
        #expect(norm("https://example.com/x?UTM_Source=a&FBCLID=b") == "https://example.com/x")
    }

    @Test("drops a trailing slash but never the root slash")
    func trailingSlash() {
        #expect(norm("https://example.com/docs/") == "https://example.com/docs")
        #expect(norm("https://example.com/docs///") == "https://example.com/docs")
        #expect(norm("https://example.com/") == "https://example.com")
    }

    @Test("a bare domain is treated as https so it dedupes against the full form")
    func schemeless() {
        #expect(norm("github.com/a/b") == "https://github.com/a/b")
        #expect(ResourceURL.sameResource("github.com/a/b/", "https://WWW.github.com/a/b?utm_source=x"))
    }

    @Test("http and https are different resources — the scheme is not rewritten")
    func schemeKept() {
        #expect(norm("HTTP://Example.com/a") == "http://example.com/a")
        #expect(!ResourceURL.sameResource("http://example.com/a", "https://example.com/a"))
    }

    @Test("rejects anything that is not a usable http url")
    func rejects() {
        #expect(norm("") == nil)
        #expect(norm("   ") == nil)
        #expect(norm("not a url") == nil)
        #expect(norm("mailto:someone@example.com") == nil)
        #expect(norm("ftp://example.com/x") == nil)
        #expect(norm("localhost") == nil)
    }

    @Test("trims surrounding whitespace before parsing")
    func whitespace() {
        #expect(norm("  https://example.com/a  ") == "https://example.com/a")
    }

    @Test("keeps the port and the query order")
    func portAndOrder() {
        #expect(norm("https://example.com:8443/a?b=2&a=1") == "https://example.com:8443/a?b=2&a=1")
    }

    @Test("sameResource is nil-safe")
    func sameResourceNils() {
        #expect(!ResourceURL.sameResource(nil, "https://example.com"))
        #expect(!ResourceURL.sameResource("https://example.com", nil))
        #expect(!ResourceURL.sameResource(nil, nil))
    }

    @Test("schemeless strips the scheme for the Notion contains filter")
    func schemelessForm() {
        #expect(ResourceURL.schemeless("https://www.github.com/a/b/") == "github.com/a/b")
        #expect(ResourceURL.schemeless("nonsense") == nil)
    }
}

@Suite("Resource model")
struct ResourceModelTests {
    @Test("only the ten known categories survive, in canonical order and deduped")
    func categoryFiltering() {
        let cleaned = Resource.sanitizedCategories(["Tools", "Productivity", "GitHub", "tools", "Claude Code", "Tools"])
        #expect(cleaned == ["Claude Code", "Tools", "GitHub"])
    }

    @Test("an all-invalid category list is left empty, never substituted")
    func categoryEmptied() {
        #expect(Resource.sanitizedCategories(["Productivity", "Misc"]).isEmpty)
        #expect(Resource.sanitizedCategories([]).isEmpty)
    }

    @Test("the id is the normalized url, lowercased")
    func idFromURL() throws {
        let r = try #require(Resource.make(
            name: "Raycast", url: "https://WWW.Raycast.com/Extensions/?utm_source=x",
            category: ["Tools"], summary: "launcher"))
        #expect(r.id == "https://raycast.com/extensions")
        #expect(r.url == "https://raycast.com/Extensions")
    }

    @Test("without a url the id is a slug of the name")
    func idFromName() throws {
        let r = try #require(Resource.make(name: "Claude Code!", url: nil, category: [], summary: ""))
        #expect(r.id == "claude-code")
        #expect(r.url == nil)
    }

    @Test("an unusable url falls back to the name slug rather than being dropped")
    func badURLFallsBack() throws {
        let r = try #require(Resource.make(name: "Some Tool", url: "not a url", category: [], summary: ""))
        #expect(r.id == "some-tool")
        #expect(r.url == nil)
    }

    @Test("a nameless resource is not made at all")
    func namelessDropped() {
        #expect(Resource.make(name: "   ", url: "https://example.com", category: [], summary: "") == nil)
    }

    @Test("the summary is one line and capped at 200 characters")
    func summaryCapped() throws {
        let r = try #require(Resource.make(
            name: "X", url: nil, category: [], summary: "a\nb " + String(repeating: "z", count: 300)))
        #expect(r.summary.count == Resource.summaryLimit)
        #expect(!r.summary.contains("\n"))
        #expect(r.summary.hasPrefix("a b "))
    }
}

@Suite("Resource merging and round-tripping")
struct ResourcesFileTests {
    func resource(_ id: String, pushed: Bool = false, name: String = "n") -> Resource {
        Resource(id: id, name: name, url: nil, category: ["Tools"], summary: "s", pushedToNotion: pushed)
    }

    @Test("a re-extracted resource keeps pushedToNotion")
    func pushedSurvivesReExtraction() {
        let merged = ResourcesFile.merge(
            existing: [resource("a", pushed: true), resource("b")],
            fresh: [resource("a", name: "renamed"), resource("b")])

        #expect(merged.count == 2)
        #expect(merged[0].pushedToNotion)
        #expect(merged[0].name == "renamed")
        #expect(!merged[1].pushedToNotion)
    }

    @Test("a pushed resource the model no longer returns is kept — its Notion row exists")
    func pushedSurvivesDisappearing() {
        let merged = ResourcesFile.merge(existing: [resource("gone", pushed: true)], fresh: [resource("new")])
        #expect(merged.map(\.id) == ["new", "gone"])
        #expect(merged[1].pushedToNotion)
    }

    @Test("an unpushed resource the model no longer returns is dropped")
    func unpushedDisappears() {
        let merged = ResourcesFile.merge(existing: [resource("gone")], fresh: [resource("new")])
        #expect(merged.map(\.id) == ["new"])
    }

    @Test("duplicate ids in one fresh result collapse to the first")
    func freshDuplicates() {
        let merged = ResourcesFile.merge(existing: [], fresh: [resource("a", name: "first"), resource("a", name: "second")])
        #expect(merged.count == 1)
        #expect(merged[0].name == "first")
    }

    @Test("resources.json round-trips through the standard coder")
    func roundTrip() throws {
        let file = ResourcesFile(v: StageVersions.extract, resources: [
            resource("https://example.com", pushed: true),
            Resource(id: "no-url", name: "No URL", url: nil, category: [], summary: ""),
        ])

        let data = try NeatJSON.encoder.encode(file)
        #expect(try NeatJSON.decoder.decode(ResourcesFile.self, from: data) == file)

        // Self-describing on disk: the version is part of the file, not implied.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"v\""))
        #expect(text.contains("\"resources\""))
    }

    @Test("an empty result is a valid, encodable answer")
    func emptyIsValid() throws {
        let data = try NeatJSON.encoder.encode(ResourcesFile(resources: []))
        #expect(try NeatJSON.decoder.decode(ResourcesFile.self, from: data).resources.isEmpty)
    }
}

@Suite("Stages decoding")
struct StagesCompatibilityTests {
    /// Every item.json on disk predates the extract stage.
    @Test("an item.json with no extract key still decodes, with extract not run")
    func missingExtractKey() throws {
        // The versions are interpolated, not literals: this test is about the
        // missing `extract` key, and a later version bump elsewhere must not
        // turn it red for an unrelated reason.
        let json = """
            {"id":{"platform":"tiktok","nativeID":"1"},"url":"https://x","platform":"tiktok",
             "stages":{"fetch":{"done":true,"skipped":false,"v":\(StageVersions.fetch)},
                       "transcribe":{"done":true,"skipped":false,"v":\(StageVersions.transcribe)},
                       "onscreen":{"done":true,"skipped":false,"v":\(StageVersions.onscreen)}}}
            """
        let item = try NeatJSON.decoder.decode(Item.self, from: Data(json.utf8))
        #expect(item.stages.extract == StageState())
        #expect(item.stages.extract.needsRun(currentVersion: StageVersions.extract))
        #expect(!item.stages.onscreen.needsRun(currentVersion: StageVersions.onscreen))
    }
}

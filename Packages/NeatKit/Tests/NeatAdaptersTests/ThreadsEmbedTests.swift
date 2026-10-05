import Foundation
import Testing

@testable import NeatAdapters

/// Fixtures are verbatim markup from real embed pages
/// (`https://www.threads.com/t/<code>/embed/`), with only the CDN query strings
/// truncated. Parsing is tested against these rather than against the network,
/// so a Threads markup change shows up as a failing test and not as an empty
/// folder six months later.
@Suite("Threads embed parsing")
struct ThreadsEmbedTests {
    /// A carousel post: avatar, mentions in the body, and three attachments of
    /// which only the middle one is an image.
    static let carousel = """
        <div class="AvatarContainer"><img class="img" src="https://scontent.cdninstagram.com/v/t51.82787-19/550174606_17925811725103224_n.jpg?stp=dst-jpg_s100x100_tt6&amp;_nc_cat=108" alt="" /></div>\
        <a href="https://www.threads.com/&#064;zuck" class="HeaderLink"><span>zuck</span></a><div class="VerifiedBadge"></div>\
        <span class="BodyTextContainer"><span>Our new line of </span>\
        <a href="https://www.threads.com/&#064;metaglasses" target="_blank">&#064;metaglasses</a>\
        <span> is available today. Three shapes, 26 style combos.</span></span></span>\
        <div class="MediaScrollContainerFull MediaScrollContainer"><div class="MediaContainer">\
        <div class="MediaScrollImageContainer"><video controls="1" loop="1" height="300" class="">\
        <source src="https://instagram.fna.fbcdn.net/o1/v/t16/f2/m84/AQOTRrCQ.mp4?_nc_cat=107" type="video/mp4" /></video></div>\
        <div class="MediaScrollImageContainer"><img class="img" src="https://scontent.cdninstagram.com/v/t51.82787-15/728809712_17974875099103224_n.webp?stp=dst-jpg_e35_tt6&amp;_nc_cat=103" alt="" /></div>\
        <div class="MediaScrollImageContainer"><video controls="1" loop="1" height="300" class="">\
        <source src="https://instagram.fna.fbcdn.net/o1/v/t16/f2/m84/AQMq6Zzr.mp4?_nc_cat=101" type="video/mp4" /></video></div>\
        </div></div><div class="PostDateContainer"><span class="Timestamp">12:26 PM &#183; Sep 2, 2026</span></div>
        """

    /// A single-image post. The body carries the escaped punctuation that
    /// Threads applies to anything code-shaped.
    static let singleImage = """
        <div class="AvatarContainer"><img class="img" src="https://scontent.cdninstagram.com/v/t51.82787-19/550174606_n.jpg?stp=dst-jpg_s100x100_tt6" alt="" /></div>\
        <a href="https://www.threads.com/&#064;0xjessel" class="HeaderLink"><span>0xjessel</span></a>\
        <span class="BodyTextContainer"><span>the route is `/intent/post?text=&#123;...&#125;`, ping &#064;me</span></span></span>\
        <div class="SoloMediaContainer"><div class="SingleInnerMediaContainer">\
        <img class="img" src="https://scontent.cdninstagram.com/v/t51.82787-15/792756314_17986039116103224_n.webp?stp=dst-jpg_e35_tt6&amp;_nc_cat=102" alt="" /></div></div>
        """

    /// Threads answers a deleted, private or never-existent post with HTTP 200
    /// and this shell, so the missing content is the only signal there is.
    static let emptyShell = """
        <!DOCTYPE html><html lang="en" id="facebook" class="no_js"><head><meta charset="utf-8" />\
        </head><body class="_605a"><div class="_9dls"></div></body></html>
        """

    @Test("reads the body text, including link labels and escaped punctuation")
    func readsBody() throws {
        let post = try ThreadsEmbed.parse(html: Self.carousel)
        #expect(post.text == "Our new line of @metaglasses is available today. Three shapes, 26 style combos.")

        let solo = try ThreadsEmbed.parse(html: Self.singleImage)
        #expect(solo.text == "the route is `/intent/post?text={...}`, ping @me")
    }

    @Test("takes every attachment image and never the avatar")
    func readsCarouselImages() throws {
        let post = try ThreadsEmbed.parse(html: Self.carousel)
        // Three attachments, but two are videos: the embed carries the mp4 and
        // no still, so there is exactly one frame to OCR.
        #expect(post.imageURLs.count == 1)
        #expect(post.imageURLs[0].absoluteString.contains("t51.82787-15/728809712"))
        // The avatar is a `-19` profile-pic URL and must never reach `frames/`.
        #expect(!post.imageURLs.contains { $0.absoluteString.contains("t51.82787-19") })
    }

    @Test("reads a lone attachment out of its own container")
    func readsSingleImage() throws {
        let post = try ThreadsEmbed.parse(html: Self.singleImage)
        #expect(post.imageURLs.count == 1)
        #expect(post.imageURLs[0].absoluteString.contains("792756314"))
        // `&amp;` in the CDN query has to be decoded or the URL 400s.
        #expect(post.imageURLs[0].absoluteString.contains("&_nc_cat=102"))
        #expect(!post.imageURLs[0].absoluteString.contains("&amp;"))
    }

    @Test("reads the author off the header link")
    func readsAuthor() throws {
        #expect(try ThreadsEmbed.parse(html: Self.carousel).author == "zuck")
        #expect(try ThreadsEmbed.parse(html: Self.singleImage).author == "0xjessel")
    }

    @Test("an empty shell is reported, not silently accepted")
    func emptyShellThrows() {
        #expect(throws: ThreadsEmbedError.postUnavailable("/t/gone/embed/")) {
            _ = try ThreadsEmbed.parse(html: Self.emptyShell, source: "/t/gone/embed/")
        }
    }

    /// A text-only post is a real post: `body.txt` is the payload and there is
    /// simply nothing for `frames/`.
    @Test("a post with text and no attachments still parses")
    func textOnlyParses() throws {
        let html = "<span class=\"BodyTextContainer\"><span>just words</span></span></span><div class=\"PostDateContainer\"></div>"
        let post = try ThreadsEmbed.parse(html: html)
        #expect(post.text == "just words")
        #expect(post.imageURLs.isEmpty)
    }

    @Test(
        "decodes the entity forms Threads actually emits",
        arguments: [
            ("plain text", "plain text"),
            ("a &amp; b", "a & b"),
            ("&#064;user", "@user"),
            ("&#123;x&#125;", "{x}"),
            ("&quot;quoted&quot;", "\"quoted\""),
            ("&lt;tag&gt;", "<tag>"),
            ("&#x1F9F5;", "\u{1F9F5}"),
            // A bare ampersand in prose must survive rather than eat the rest.
            ("rock & roll & jazz", "rock & roll & jazz"),
            // An entity we do not know is left alone, not dropped.
            ("&thinsp;x", "&thinsp;x"),
        ]
    )
    func decodesEntities(input: String, expected: String) {
        #expect(ThreadsEmbed.decodeEntities(input) == expected)
    }
}

import XCTest
import ReaderContent
@testable import ReaderRuntime

final class NativeArticleTests: XCTestCase {
    func testHyphenationAddsOnlyDiscretionaryBreaks() {
        let original = "Internationalization and accessibility"
        let displayed = ReaderHyphenation.text(original, language: "en")
        XCTAssertTrue(displayed.contains("\u{00AD}"))
        XCTAssertEqual(displayed.replacingOccurrences(of: "\u{00AD}", with: ""), original)
        XCTAssertEqual(ReaderHyphenation.text("", language: "en"), "")
        XCTAssertEqual(ReaderHyphenation.text("12345 😀", language: "en"), "12345 😀")
        XCTAssertEqual(ReaderHyphenation.text(original, language: "und"), original)
    }

    func testHyphenationVisitsEveryWordDespitePunctuationAndShortEnding() {
        for (language, words) in [
            ("en", ["internationalization", "accessibility"]),
            ("ru", ["международный", "программирование"])
        ] {
            // Dictionary availability depends on the OS; compare paragraph
            // output with the same OS's individual-word behavior.
            let paragraph = "😀 " + words.joined(separator: ", ") + " — a!"
            let expected = "😀 " + words.map { ReaderHyphenation.text($0, language: language) }
                .joined(separator: ", ") + " — a!"
            XCTAssertEqual(ReaderHyphenation.text(paragraph, language: language), expected, language)
            XCTAssertEqual(expected.replacingOccurrences(of: "\u{00AD}", with: ""), paragraph)
        }
    }

    @MainActor private func page(_ body: String, url: String, hidden: String = "") async -> ReaderPage {
        let subscription = Subscription(name: "Feed", address: "https://example.org/feed", kind: url.contains("t.me") ? "telegram" : "rss")
        let item = RemoteArticle(id: "story", title: "Headline", url: url, text: "", published: Date())
        let link = ArticleLink(Article(item: item, subscription: subscription), hiddenText: hidden)
        let doc = ReaderDocument(link, content: CachedArticle(text: "", html: body, feedHTML: body))
        let cache = MediaCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return await ReaderPage.prepare(.init(article: doc, hiddenText: hidden, palette: .saved(), version: 0), cache: cache)
    }

    func testPreviousPageRemainsAvailableWhileAnotherArticleIsPreparing() async {
        let first = await page("<p>One</p>", url: "https://example.org/one")
        let second = await page("<p>Two</p>", url: "https://example.org/two")
        XCTAssertEqual(ReaderPage.visible(for: second.input, launch: nil, prepared: first)?.input, first.input)
        XCTAssertEqual(ReaderPage.visible(for: second.input, launch: second, prepared: first)?.input, second.input)
        let filtered = ReaderPage.Input(article: first.input.article, hiddenText: "One", palette: first.input.palette, version: 1)
        XCTAssertNil(ReaderPage.visible(for: filtered, launch: nil, prepared: first))
    }
    func testTelegramTextAndBothPhotosKeepTheirOrder() async throws {
        let page = await page("<p>first HIDE</p><img src='https://example.org/a.jpg'><p>second</p><img src='https://example.org/b.jpg'>",
                              url: "https://t.me/news/1", hidden: "HIDE")
        let blocks = try XCTUnwrap(page.nativeBody).blocks
        XCTAssertEqual(blocks.count, 4)
        guard blocks.count == 4, case .text(_, let first) = blocks[0], case .image(let a, _, _, _) = blocks[1],
              case .text(_, let second) = blocks[2], case .image(let b, _, _, _) = blocks[3] else { return XCTFail("Unexpected block order") }
        XCTAssertEqual(first.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines), "first")
        XCTAssertEqual(second.map(\.text).joined(), "second")
        XCTAssertEqual([a.lastPathComponent, b.lastPathComponent], ["a.jpg", "b.jpg"])
    }

    func testRSSKeepsInlineLinkFormattingAndCaption() async throws {
        let page = await page("""
            <h2>Analysis</h2><p>Read <a href="/source"><strong>the source</strong></a>.</p>
            <figure><img alt="Map" src="/map.jpg"><figcaption>Map of the region</figcaption></figure>
            """, url: "https://example.org/story")
        let blocks = try XCTUnwrap(page.nativeBody).blocks
        guard blocks.count == 4, case .text(.heading, _) = blocks[0], case .text(.paragraph, let runs) = blocks[1],
              case .image(let url, let alt, _, _) = blocks[2], case .text(.caption, let caption) = blocks[3] else { return XCTFail("Missing RSS content") }
        XCTAssertTrue(runs.contains { $0.bold && $0.link?.absoluteString == "https://example.org/source" })
        XCTAssertEqual(url.absoluteString, "https://example.org/map.jpg")
        XCTAssertEqual(alt, "Map")
        XCTAssertEqual(caption.map(\.text).joined(), "Map of the region")
    }

    func testVideoAndYouTubeAreNativeBlocksUntilPlayback() async throws {
        let page = await page("<video src='https://example.org/movie.mp4' poster='https://example.org/poster.jpg'></video><a href='https://youtu.be/abcdefghijk'>Video</a>", url: "https://example.org/story")
        let blocks = try XCTUnwrap(page.nativeBody).blocks
        XCTAssertTrue(blocks.contains(.video(URL(string: "https://example.org/movie.mp4")!, poster: URL(string: "https://example.org/poster.jpg")!)))
        XCTAssertTrue(blocks.contains(.youtube("abcdefghijk")))
    }
    func testTableKeepsCompleteWebRepresentation() async {
        let page = await page("<table><tr><td>Cell</td></tr></table>", url: "https://example.org/story")
        XCTAssertNil(page.nativeBody)
        guard case .web(let html) = page.content else { return XCTFail("Expected table fallback") }
        XCTAssertTrue(html.contains("<td>Cell</td>"))
        XCTAssertTrue(html.contains("<html lang="))
        XCTAssertTrue(html.contains("hyphens:auto"))
    }
}

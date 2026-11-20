import XCTest
import ReaderContent
@testable import ReaderRuntime

final class NativeArticleTests: XCTestCase {
    @MainActor private func page(_ body: String, url: String, hidden: String = "") async -> ReaderPage {
        let subscription = Subscription(name: "Feed", address: "https://example.org/feed", kind: url.contains("t.me") ? "telegram" : "rss")
        let item = RemoteArticle(id: "story", title: "Headline", url: url, text: "", published: Date())
        let link = ArticleLink(Article(item: item, subscription: subscription), hiddenText: hidden)
        let doc = ReaderDocument(link, content: CachedArticle(text: "", html: body, feedHTML: body))
        let cache = MediaCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        return await ReaderPage.prepare(.init(article: doc, hiddenText: hidden, palette: .saved(), version: 0), cache: cache)
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
        XCTAssertTrue(page.html.contains("<td>Cell</td>"))
    }
}

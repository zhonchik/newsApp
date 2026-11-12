import XCTest
@testable import ReaderContent

final class ContentRulesTests: XCTestCase {
    func testNPlusOneSelectsOnlyFirstArticle() throws {
        let page = "<header>Menu</header><section data-heading-wrap><div class='n1_material'><p>Requested article</p><img src='/photo.jpg'></div><div class='n1_material'><p>Final paragraph</p></div></section><section><div class='n1_material'><p>Another article</p></div></section>"
        let result = try XCTUnwrap(ContentRules.articleBody(page: page, url: "https://nplus1.ru/news/story"))
        XCTAssertTrue(result.contains("Requested article"))
        XCTAssertTrue(result.contains("Final paragraph"))
        XCTAssertTrue(result.contains("https://nplus1.ru/photo.jpg"))
        XCTAssertFalse(result.contains("Another article"))
        XCTAssertFalse(result.contains("Menu"))
    }
    func testMacRumorsExcludesPopularStories() throws {
        let page = "<article><div class='js-content'><p>Story</p></div></article><h2>Popular Stories</h2><p>Unrelated</p>"
        let result = try XCTUnwrap(ContentRules.articleBody(page: page, url: "https://www.macrumors.com/story"))
        XCTAssertTrue(result.contains("Story"))
        XCTAssertFalse(result.contains("Popular Stories"))
        XCTAssertFalse(result.contains("Unrelated"))
    }
    func testCachedMacRumorsContentIsCleaned() throws {
        let result = try ReaderContent.html(body: "<p>Story</p><h2>Popular Stories</h2><p>Unrelated</p>", feed: "", baseURL: "https://www.macrumors.com/story")
        XCTAssertTrue(result.contains("Story"))
        XCTAssertFalse(result.contains("Unrelated"))
    }
    func testF1NewsExcludesFooterAndAdjacentStories() throws {
        let page = "<article class='post'><div class='post_content'><p>Story</p></div><footer>Нашли опечатку?<nav class='post_more'>Следующая новость</nav></footer></article>"
        let result = try XCTUnwrap(ContentRules.articleBody(page: page, url: "https://www.f1news.ru/news/story"))
        XCTAssertTrue(result.contains("Story"))
        XCTAssertFalse(result.contains("опечатку"))
        XCTAssertFalse(result.contains("Следующая"))
    }
    func testHiddenPhraseAcrossInlineTagsPreservesFormatting() throws {
        let body = "<p>НАСТОЯЩИЙ МАТЕРИАЛ <b>ПРОИЗВЕДЕН ИНОСТРАННЫМ АГЕНТОМ</b> ГАЛЛЯМОВЫМ АББАСОМ РАДИКОВИЧЕМ. 18+</p><p><strong>Actual post</strong> with <a href='https://example.com'>link</a>.</p>"
        let result = try ReaderContent.html(body: body, feed: "", baseURL: "https://t.me/abbasgallyamovpolitics/42", hiddenText: ContentRules.telegramNotice)
        XCTAssertFalse(result.contains("НАСТОЯЩИЙ"))
        XCTAssertFalse(result.contains("18+"))
        XCTAssertTrue(result.contains("<strong>Actual post</strong>"))
        XCTAssertTrue(result.contains("https://example.com"))
    }
    func testEmptyFilterKeepsOriginalText() throws {
        let result = try ReaderContent.html(body: "<p>Keep this notice</p>", feed: "", baseURL: "https://t.me/other/42")
        XCTAssertTrue(result.contains("Keep this notice"))
        XCTAssertEqual(ContentRules.defaultHiddenText(address: "@other"), "")
    }
    func testUnrecognizedLayoutFallsBackToReadability() throws {
        XCTAssertNil(try ContentRules.articleBody(page: "<p>Unknown layout</p>", url: "https://nplus1.ru/news/story"))
    }
    func testTelegramHeadlinePolicy() {
        XCTAssertTrue(ContentRules.isTelegram("https://t.me/channel/42"))
        XCTAssertFalse(ContentRules.isTelegram("https://example.com/story"))
    }
}

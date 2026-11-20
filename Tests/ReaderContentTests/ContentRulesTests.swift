import XCTest
@testable import ReaderContent

final class ContentRulesTests: XCTestCase {
    func testDefinitionsStayAttachedToTheirInlineTerms() throws {
        let body = """
        <p>Before <dfn title="A short muscle contraction.">twitch</dfn>, after.
        <dfn title="A short chain of amino acids." onclick="alert(1)">peptide</dfn>.
        <dfn>Word</dfn>.</p>
        """
        for url in ["https://publisher.example/story", "https://another.example/article"] {
            let result = try ReaderContent.html(body: body, feed: "", baseURL: url)
            XCTAssertTrue(result.contains("Before <button type=\"button\" popovertarget=\"reader-definition-0\">twitch</button>"))
            XCTAssertTrue(result.contains("A short muscle contraction.</span>, after."))
            XCTAssertTrue(result.contains("popovertarget=\"reader-definition-1\">peptide</button>"))
            XCTAssertTrue(result.contains("id=\"reader-definition-1\" popover=\"auto\" role=\"note\" aria-label=\"peptide\">A short chain of amino acids.</span>"))
            XCTAssertTrue(result.contains("<dfn>Word</dfn>."))
            XCTAssertEqual(result.components(separatedBy: "A short muscle contraction.").count, 2)
            XCTAssertFalse(result.contains("onclick"))
        }
    }

    func testHiddenPhraseAcrossInlineTagsPreservesFormatting() throws {
        let body = "<p>REPEATED <b>SUBSCRIPTION</b> NOTICE.</p><p><strong>Actual post</strong> with <a href='https://example.com'>link</a>.</p>"
        let result = try ReaderContent.html(body: body, feed: "", baseURL: "https://example.com/article", hiddenText: "Repeated subscription notice.")
        XCTAssertFalse(result.contains("REPEATED"))
        XCTAssertFalse(result.contains("NOTICE"))
        XCTAssertTrue(result.contains("<strong>Actual post</strong>"))
        XCTAssertTrue(result.contains("https://example.com"))
    }

    func testEmptyFilterKeepsOriginalText() throws {
        let result = try ReaderContent.html(body: "<p>Keep this notice</p>", feed: "", baseURL: "https://example.com/article", hiddenText: "")
        XCTAssertTrue(result.contains("Keep this notice"))
    }

    func testTelegramHeadlinePolicy() {
        XCTAssertTrue(ContentRules.isTelegram("https://t.me/channel/42"))
        XCTAssertFalse(ContentRules.isTelegram("https://example.com/story"))
    }
}

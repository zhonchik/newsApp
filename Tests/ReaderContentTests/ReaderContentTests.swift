import XCTest
@testable import ReaderContent

final class ReaderContentTests: XCTestCase {
    let base = "https://www.f1news.ru/news/f1-192505.html"
    let feed = "<img src='https://c.f1news.ru/userfiles/claire_williams/192505.jpg'><p>Summary</p>"
    func testFeedPhotoSurvivesFullTextReplacement() throws {
        let result = try ReaderContent.html(body: "<p>Complete article</p>", feed: feed, baseURL: base)
        XCTAssertTrue(result.contains("192505.jpg"))
        XCTAssertTrue(result.contains("Complete article"))
        XCTAssertFalse(result.contains("Summary"))
    }
    func testExtractedPhotoAvoidsDuplicateFeedPhoto() throws {
        let result = try ReaderContent.html(body: "<img src='//bc.f1ne.ws/userfiles/claire_williams/192505.jpg'><p>Article</p>", feed: feed, baseURL: base)
        XCTAssertTrue(result.contains("https://bc.f1ne.ws/"))
        XCTAssertFalse(result.contains("https://c.f1news.ru/"))
    }
    func testUnsafeFeedMarkupIsNotInserted() throws {
        let result = try ReaderContent.html(body: "<p>Article</p>", feed: "<script>alert(1)</script><img src='javascript:alert(1)'>", baseURL: base)
        XCTAssertFalse(result.contains("script"))
        XCTAssertFalse(result.contains("alert"))
    }
}

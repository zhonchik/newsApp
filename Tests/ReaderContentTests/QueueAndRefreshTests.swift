import XCTest
@testable import ReaderContent

final class QueueAndRefreshTests: XCTestCase {
    func testReaddedFeedAndTrackingLinksKeepSameArticleIdentity() {
        let first = ArticleIdentity.key(url: "https://example.com/story?utm_source=rss#top", fallback: "old-subscription-guid")
        let again = ArticleIdentity.key(url: "https://example.com/story", fallback: "new-subscription-guid")
        XCTAssertEqual(first, again)
        XCTAssertNotEqual(first, ArticleIdentity.key(url: "https://example.com/other"))
    }
    func testMeaningfulQueryParametersArePreserved() {
        XCTAssertNotEqual(ArticleIdentity.key(url: "https://example.com/article?id=1"), ArticleIdentity.key(url: "https://example.com/article?id=2"))
    }
    func testTemporaryStartupFailureIsRetried() async throws {
        var attempts = 0
        let result = try await NetworkRetry.perform(delay: .zero) {
            attempts += 1
            if attempts == 1 { throw URLError(.networkConnectionLost) }
            return "feed"
        }
        XCTAssertEqual(result, "feed")
        XCTAssertEqual(attempts, 2)
    }
    func testPermanentFailureDoesNotRetry() async {
        var attempts = 0
        do {
            let _: String = try await NetworkRetry.perform(delay: .zero) {
                attempts += 1; throw URLError(.badURL)
            }
            XCTFail("Expected failure")
        } catch { XCTAssertEqual(attempts, 1) }
    }
    func testMacRumorsImageRenditionsAreDeduplicated() throws {
        let body = "<img src='https://images.macrumors.com/t/hash-a/800x0/article-new/2026/11/photo.jpg?lossy'><p>Story</p>"
        let feed = "<img src='https://images.macrumors.com/t/hash-b/400x0/article-new/2026/11/photo.jpg'><img src='https://images.macrumors.com/article-new/2026/11/photo.jpg'>"
        let result = try ReaderContent.html(body: body, feed: feed, baseURL: "https://www.macrumors.com/story")
        XCTAssertEqual(result.components(separatedBy: "<img").count - 1, 1)
        XCTAssertTrue(result.contains("Story"))
    }
    func testNPlusOneAdsRemovedWithoutRemovingArticleText() throws {
        let body = "<p>Story discusses advertising.</p><div class='advertisement'><img src='https://example.com/ad.jpg'>Advertisement</div><a id='adv-banner-link-text' href='https://example.com'>Buy this</a><p>Last paragraph</p>"
        let result = try ReaderContent.html(body: body, feed: "", baseURL: "https://nplus1.ru/news/story")
        XCTAssertFalse(result.contains("ad.jpg"))
        XCTAssertFalse(result.contains("Buy this"))
        XCTAssertTrue(result.contains("Story discusses advertising"))
        XCTAssertTrue(result.contains("Last paragraph"))
    }
}

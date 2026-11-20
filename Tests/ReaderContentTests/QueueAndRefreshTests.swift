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
    func testLinkedArticleImageUsesOriginalFromFeed() throws {
        let original = "https://cdn.example.com/photos/My%20Photo.jpg?version=2"
        let body = "<a href='/related-story'><img src='https://cdn.example.com/render/hash/400x0/photos/My%20Photo.jpg?lossy' alt='Photo'></a><p>Story</p>"
        let feed = "<img src='\(original)'>"
        let result = try ReaderContent.html(body: body, feed: feed, baseURL: "https://publisher.example.com/story")
        XCTAssertEqual(result.components(separatedBy: "<img").count - 1, 1)
        XCTAssertTrue(result.contains(original))
        XCTAssertFalse(result.contains("/render/"))
        XCTAssertTrue(result.contains("href=\"https://publisher.example.com/related-story\""))
        XCTAssertTrue(result.contains("alt=\"Photo\""))
        XCTAssertTrue(result.contains("data-reader-original"))
        XCTAssertTrue(result.contains("Story"))
    }
    func testAdsRemovedWithoutRemovingArticleText() throws {
        let body = "<p>Story discusses advertising.</p><div class='advertisement'><img src='https://example.com/ad.jpg'>Advertisement</div><a data-ad='true' href='https://example.com'>Buy this</a><p>Last paragraph</p>"
        let result = try ReaderContent.html(body: body, feed: "", baseURL: "https://publisher.example/news/story")
        XCTAssertFalse(result.contains("ad.jpg"))
        XCTAssertFalse(result.contains("Buy this"))
        XCTAssertTrue(result.contains("Story discusses advertising"))
        XCTAssertTrue(result.contains("Last paragraph"))
    }
}

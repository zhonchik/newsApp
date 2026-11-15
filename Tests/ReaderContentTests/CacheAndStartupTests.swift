import XCTest
@testable import ReaderContent

final class CacheAndStartupTests: XCTestCase {
    func testStartupRestoresSavedArticleAfterSnapshotArrives() {
        XCTAssertEqual(ReaderSelection.restored(keys: [], current: "", saved: "saved"), "")
        XCTAssertEqual(ReaderSelection.restored(keys: ["first", "saved"], current: "", saved: "saved"), "saved")
        XCTAssertEqual(ReaderSelection.restored(keys: ["first"], current: "removed", saved: "removed"), "first")
        XCTAssertEqual(ReaderSelection.restored(keys: ["first", "selected"], current: "selected", saved: "first"), "selected")
    }
    func testCacheEvictsLeastRecentlyUsedUntilWithinLimit() {
        let items = [
            CachePolicy.Item(key: "old", bytes: 30, accessed: Date(timeIntervalSince1970: 1)),
            CachePolicy.Item(key: "recent", bytes: 50, accessed: Date(timeIntervalSince1970: 3)),
            CachePolicy.Item(key: "middle", bytes: 40, accessed: Date(timeIntervalSince1970: 2))
        ]
        XCTAssertEqual(CachePolicy.evictions(items, limit: 100), ["old"])
        XCTAssertEqual(CachePolicy.evictions(items, limit: 60), ["old", "middle"])
        XCTAssertEqual(CachePolicy.evictions(items, limit: 0), ["old", "middle", "recent"])
        XCTAssertEqual(CachePolicy.evictions(items, limit: 120), [])
    }
    func testOversizedEntryCannotKeepCacheOverLimit() {
        let item = CachePolicy.Item(key: "oversized", bytes: 200, accessed: Date())
        XCTAssertEqual(CachePolicy.evictions([item], limit: 100), ["oversized"])
    }
    func testCachedTextAndOriginalFeedSurviveDiskRoundTrip() throws {
        let article = CachedArticle(text: "Offline text", html: "<p>Full text</p>", feedHTML: "<img src='https://example.com/image.jpg'>", revision: 5)
        let data = try JSONEncoder().encode(article)
        XCTAssertEqual(try JSONDecoder().decode(CachedArticle.self, from: data), article)
    }
}

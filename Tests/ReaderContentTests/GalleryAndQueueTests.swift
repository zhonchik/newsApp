import XCTest
@testable import ReaderContent

final class GalleryAndQueueTests: XCTestCase {
    func testImageOnlyGalleryBypassesTextExtraction() throws {
        let page = "<img src='/logo.png'><a class='b-gallery__media'><img class='giThumbnail' src='//gi.f1ne.ws/im/c/300x200/gallery/2026/gp/photo.jpg' width='300' height='200'></a><div class='pagination'><a rel='next' href='?page=2'>Next</a></div>"
        let result = try XCTUnwrap(ContentRules.articleBody(page: page, url: "https://www.f1news.ru/gallery/v/2026/gp/saopaulo/0611/"))
        XCTAssertTrue(result.contains("https://bc.f1ne.ws/gallery/2026/gp/photo.jpg"))
        XCTAssertFalse(result.contains("logo.png"))
        XCTAssertTrue(result.contains("More gallery photos"))
        XCTAssertTrue(result.contains("?page=2"))
    }
    func testExistingNoticeFilterMatchesLiveChannelVariant() throws {
        let html = "<p>НАСТОЯЩИЙ МАТЕРИАЛ ПРОИЗВЕДЕН <b>И РАСПРОСТРАНЕН</b> ИНОСТРАННЫМ АГЕНТОМ ГАЛЛЯМОВЫМ АББАСОМ РАДИКОВИЧЕМ. 18+</p><p>Actual post</p>"
        let result = try ReaderContent.html(body: html, feed: "", baseURL: "https://t.me/abbasgallyamovpolitics/42", hiddenText: ContentRules.telegramNotice)
        XCTAssertFalse(result.contains("РАСПРОСТРАНЕН"))
        XCTAssertFalse(result.contains("18+"))
        XCTAssertTrue(result.contains("Actual post"))
    }
    func testReadHistoryAlwaysPrecedesUnreadRegardlessOfArrivalOrder() {
        struct Entry { let id: String; var read: Bool; var readPosition: Int; let queuePosition: Int }
        var entries = [Entry(id: "early-unread", read: false, readPosition: 0, queuePosition: 1), Entry(id: "read", read: true, readPosition: 1, queuePosition: 2), Entry(id: "later-unread", read: false, readPosition: 0, queuePosition: 3)]
        func order() -> [String] { ReadingQueue.ordered(entries, isRead: { $0.read }, readPosition: { $0.readPosition }, queuePosition: { $0.queuePosition }).map(\.id) }
        XCTAssertEqual(order(), ["read", "early-unread", "later-unread"])
        entries[0].read = true; entries[0].readPosition = 2
        XCTAssertEqual(order(), ["read", "early-unread", "later-unread"])
        entries.append(Entry(id: "new", read: false, readPosition: 0, queuePosition: 4))
        XCTAssertEqual(order(), ["read", "early-unread", "later-unread", "new"])
    }
}

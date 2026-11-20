import XCTest
@testable import ReaderContent

final class ReadHistoryTests: XCTestCase {
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

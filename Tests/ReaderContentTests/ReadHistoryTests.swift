import XCTest
@testable import ReaderContent

final class ReadHistoryTests: XCTestCase {
    func testUnreadChronologyOverridesReverseArrivalWhilePreservingReadHistory() {
        struct Entry { let id: String; let read: Bool; let visit: Int; let arrival: Int; let day: Double }
        let entries = [
            Entry(id: "newest", read: false, visit: 0, arrival: 1, day: 30),
            Entry(id: "oldest", read: false, visit: 0, arrival: 3, day: 10),
            Entry(id: "middle", read: false, visit: 0, arrival: 2, day: 20),
            Entry(id: "read-second", read: true, visit: 2, arrival: 5, day: 1),
            Entry(id: "read-first", read: true, visit: 1, arrival: 4, day: 40),
            Entry(id: "same-date-later", read: false, visit: 0, arrival: 6, day: 20)
        ]
        let ordered = ReadingQueue.ordered(entries, isRead: { $0.read }, readPosition: { $0.visit },
            queuePosition: { $0.arrival }, published: { Date(timeIntervalSince1970: $0.day) })
        XCTAssertEqual(ordered.map(\.id), ["read-first", "read-second", "oldest", "middle", "same-date-later", "newest"])
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

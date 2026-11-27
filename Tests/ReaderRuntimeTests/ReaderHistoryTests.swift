import XCTest
@testable import ReaderRuntime

final class ReaderHistoryTests: XCTestCase {
    private func document(_ path: String) -> ReaderDocument {
        ReaderDocument(url: URL(string: "https://publisher.example/" + path)!, title: path, html: "<p>Saved content for \(path)</p>")
    }
    func testBackgroundWriterRejectsOlderSnapshots() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("history.json")
        let writer = ReaderHistoryWriter()
        var old = ReaderHistory()
        let root = document("root")
        old.select(root)
        var newest = old
        newest.scroll(key: root.key, offset: 420)
        try await writer.save(newest, to: file, revision: 2)
        try await writer.save(old, to: file, revision: 1)
        let restored = try JSONDecoder().decode(ReaderHistory.self, from: Data(contentsOf: file))
        XCTAssertEqual(restored, newest)
        var next = newest
        next.push(document("linked"))
        try await writer.save(next, to: file, revision: 3)
        XCTAssertEqual(try JSONDecoder().decode(ReaderHistory.self, from: Data(contentsOf: file)), next)
    }

    func testNestedVisitsPopAndHomeRestoreOffsets() {
        let root = document("root"), first = document("first"), second = document("second")
        var history = ReaderHistory()
        history.select(root); history.scroll(key: root.key, offset: 240)
        history.push(first); history.scroll(key: first.key, offset: 510)
        history.push(second); history.scroll(key: second.key, offset: 890)
        XCTAssertTrue(history.back())
        XCTAssertEqual(history.current?.document, first)
        XCTAssertEqual(history.current?.offset, 510)
        history.home()
        XCTAssertEqual(history.current?.document, root)
        XCTAssertEqual(history.current?.offset, 240)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertFalse(history.back(), "At the root, Back must fall through to the previous queue article")
        XCTAssertEqual(history.current?.document, root)
    }
    func testPersistenceIncludesBodiesAndEveryPosition() throws {
        let root = document("root"), child = document("child")
        var history = ReaderHistory()
        history.select(root); history.scroll(key: root.key, offset: 123)
        history.push(child); history.scroll(key: child.key, offset: 456)
        let restored = try JSONDecoder().decode(ReaderHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored, history)
        XCTAssertEqual(restored.root?.html, root.html)
        XCTAssertEqual(restored.current?.document.html, child.html)
        XCTAssertEqual(restored.entries.map(\.offset), [123, 456])
    }
    func testNewQueueSelectionDiscardsPreviousHistoryAndPositions() {
        var history = ReaderHistory()
        let root = document("root"), next = document("next")
        history.select(root); history.scroll(key: root.key, offset: 900)
        history.push(document("child"))
        history.select(next)
        XCTAssertEqual(history.entries.count, 1)
        XCTAssertEqual(history.current?.document, next)
        XCTAssertEqual(history.current?.offset, 0)
        history.scroll(key: root.key, offset: 700) // A disappearing view cannot change the new selection.
        XCTAssertEqual(history.current?.offset, 0)
    }
    func testEmptySnapshotDoesNotReplaceSavedRootOrLinkedContent() throws {
        let root = document("root"), child = document("child")
        var history = ReaderHistory()
        history.select(root); history.scroll(key: root.key, offset: 80)
        history.push(child); history.scroll(key: child.key, offset: 260)
        let before = history
        let empty = LibrarySnapshot(articles: [], subscriptions: [], savedKey: "")
        XCTAssertEqual(history.restoredSelection(root.key, snapshot: empty), root.key)
        XCTAssertEqual(history, before)
        let restored = try JSONDecoder().decode(ReaderHistory.self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored.current?.document.html, child.html)
        XCTAssertEqual(restored.entries.map(\.offset), [80, 260])
    }

    func testReloadPreservesPositionAndRepeatedURLsHaveIndependentVisits() {
        let root = document("same"), repeatVisit = document("same")
        XCTAssertNotEqual(root.key, repeatVisit.key)
        var history = ReaderHistory()
        history.select(root); history.scroll(key: root.key, offset: 90)
        history.select(root.replacingContent(title: "Updated", html: "<p>Updated body</p>"))
        XCTAssertEqual(history.current?.offset, 90)
        history.push(repeatVisit); history.scroll(key: repeatVisit.key, offset: 340)
        history.scroll(key: repeatVisit.key, offset: .nan)
        XCTAssertEqual(history.current?.offset, 340)
        history.back()
        XCTAssertEqual(history.current?.offset, 90)
        XCTAssertEqual(history.current?.document.title, "Updated")
    }
}

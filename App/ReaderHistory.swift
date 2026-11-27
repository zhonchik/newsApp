import Foundation

/// One queue article and its linked descendants. Each visit has its own scroll offset.
struct ReaderHistory: Codable, Equatable, Sendable {
    struct Entry: Codable, Equatable, Sendable {
        var document: ReaderDocument
        var offset: Double = 0
    }
    private(set) var entries: [Entry] = []
    var root: ReaderDocument? { entries.first?.document }
    var current: Entry? { entries.last }
    var canGoHome: Bool { entries.count > 1 }

    func restoredSelection(_ current: String, snapshot: LibrarySnapshot) -> String {
        // Cloud-backed snapshots can temporarily omit the saved root. Keep its offline session.
        if root?.key == current, self.current != nil { return current }
        return snapshot.restoredSelection(current)
    }
    mutating func select(_ document: ReaderDocument) {
        if root?.key != document.key { entries = [Entry(document: document)] }
        else { entries[0].document = document }
    }
    mutating func push(_ document: ReaderDocument) { entries.append(Entry(document: document)) }
    @discardableResult mutating func back() -> Bool {
        guard canGoHome else { return false }
        entries.removeLast()
        return true
    }
    mutating func home() { if let first = entries.first { entries = [first] } }
    mutating func update(_ document: ReaderDocument) {
        guard let index = entries.firstIndex(where: { $0.document.key == document.key }) else { return }
        entries[index].document = document
    }
    mutating func scroll(key: String, offset: Double) {
        guard offset.isFinite, let index = entries.firstIndex(where: { $0.document.key == key }) else { return }
        entries[index].offset = max(0, offset)
    }
}

/// Serializes disk writes off the UI actor and rejects out-of-order snapshots.
actor ReaderHistoryWriter {
    private var latestRevision: UInt64 = 0
    func save(_ history: ReaderHistory, to file: URL, revision: UInt64) throws {
        guard revision > latestRevision else { return }
        let data = try JSONEncoder().encode(history)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file, options: .atomic)
        latestRevision = revision
    }
}

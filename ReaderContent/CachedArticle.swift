import Foundation

public struct CachedArticle: Codable, Sendable, Equatable {
    public var text: String
    public var html: String
    public var feedHTML: String
    public var revision: Int
    public init(text: String, html: String, feedHTML: String, revision: Int = 0) {
        self.text = text; self.html = html; self.feedHTML = feedHTML; self.revision = revision
    }
}

public enum ReaderSelection {
    public static func restored(keys: [String], current: String, saved: String) -> String {
        if keys.contains(current) { return current }
        if keys.contains(saved) { return saved }
        return keys.first ?? ""
    }
}

public enum CachePolicy {
    public struct Item: Sendable {
        public let key: String
        public let bytes: Int
        public let accessed: Date
        public init(key: String, bytes: Int, accessed: Date) { self.key = key; self.bytes = bytes; self.accessed = accessed }
    }
    public static func evictions(_ items: [Item], limit: Int) -> [String] {
        var total = items.reduce(0) { $0 + $1.bytes }
        var result: [String] = []
        for item in items.sorted(by: { ($0.accessed, $0.key) < ($1.accessed, $1.key) }) where total > max(0, limit) {
            result.append(item.key); total -= item.bytes
        }
        return result
    }
}

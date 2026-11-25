import Foundation

public enum ReadingQueue {
    public static func ordered<T>(_ items: [T], isRead: (T) -> Bool, readPosition: (T) -> Int, queuePosition: (T) -> Int, published: ((T) -> Date)? = nil) -> [T] {
        items.enumerated().sorted { left, right in
            let a = left.element, b = right.element
            if isRead(a) != isRead(b) { return isRead(a) }
            // Arrival order can differ from chronology across feeds and restored libraries.
            // Keep read history in visit order, but present unread stories oldest first.
            if !isRead(a), let published, published(a) != published(b) {
                return published(a) < published(b)
            }
            let x = isRead(a) ? readPosition(a) : queuePosition(a)
            let y = isRead(b) ? readPosition(b) : queuePosition(b)
            return x == y ? left.offset < right.offset : x < y
        }.map(\.element)
    }
}

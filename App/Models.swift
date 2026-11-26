#if SWIFT_PACKAGE
import ReaderContent
#endif
import Foundation
import SwiftData

@Model final class Subscription {
    var id: UUID = UUID()
    var name: String = ""
    var address: String = ""
    var kind: String = "rss"
    var paused: Bool = false
    var hiddenText: String = ""
    var contentDefaultsApplied: Bool = false // Retained for existing SwiftData stores.
    var created: Date = Date()
    init(name: String, address: String, kind: String) {
        self.name = name; self.address = address; self.kind = kind
    }
}

@Model final class Article {
    var key: String = ""
    var subscriptionID: UUID = UUID()
    var title: String = ""
    var source: String = ""
    var url: String = ""
    var text: String = ""
    var html: String = ""
    var feedHTML: String = ""
    var published: Date = Date()
    var queued: Bool = false
    var queuePosition: Int = 0
    var read: Bool = false
    var readPosition: Int = 0
    var extracted: Bool = false
    var richExtracted: Bool = false
    var contentRevision: Int = 0
    init(item: RemoteArticle, subscription: Subscription) {
        key = ArticleIdentity.key(url: item.url, fallback: subscription.address + ":" + item.id)
        subscriptionID = subscription.id; title = item.title; source = subscription.name
        url = item.url; text = item.text; html = item.html; feedHTML = item.html; published = item.published; queued = subscription.paused
    }
}

@Model final class ReadingPosition {
    var key: String = "main"
    var articleKey: String = ""
    var changed: Date = Date()
    init(articleKey: String) { self.articleKey = articleKey }
}

struct RemoteArticle: Decodable, Sendable {
    let id: String
    let title: String
    let url: String
    let text: String
    let published: Date
    var html: String = ""
}

/// Only immutable values cross the library actor boundary.
struct ArticleLink: Codable, Sendable, Equatable, Identifiable {
    var id: String { key }
    let key: String
    let title: String
    let source: String
    let url: String
    let published: Date
    let read: Bool
    let hiddenText: String
    init(_ article: Article, hiddenText: String) {
        key = article.key; title = article.title; source = article.source; url = article.url
        published = article.published; read = article.read; self.hiddenText = hiddenText
    }
}
struct SubscriptionInfo: Sendable {
    let id: UUID; let name: String; let address: String; let kind: String
}
struct LibrarySnapshot: Sendable {
    let articles: [ArticleLink]
    let subscriptions: [SubscriptionInfo]
    let savedKey: String
    let indexByKey: [String: Int]
    let unreadCount: Int
    let firstUnread: String?
    let addedCount: Int

    init(articles: [ArticleLink], subscriptions: [SubscriptionInfo], savedKey: String,
         previousIndices: [String: Int]? = nil) {
        self.articles = articles
        self.subscriptions = subscriptions
        self.savedKey = savedKey
        var indices: [String: Int] = [:]
        var unread = 0, added = 0
        var first: String?
        for (index, link) in articles.enumerated() {
            if indices[link.key] == nil { indices[link.key] = index }
            if !link.read {
                unread += 1
                if first == nil { first = link.key }
            }
            if let previousIndices, previousIndices[link.key] == nil { added += 1 }
        }
        indexByKey = indices
        unreadCount = unread
        firstUnread = first
        addedCount = added
    }
    func restoredSelection(_ current: String) -> String {
        if indexByKey[current] != nil { return current }
        if indexByKey[savedKey] != nil { return savedKey }
        return articles.first?.key ?? ""
    }
}
struct ReaderDocument: Codable, Sendable, Equatable {
    let hiddenText: String
    let key: String
    var title: String
    let source: String
    let url: String
    let text: String
    var html: String
    let feedHTML: String
    let contentRevision: Int
    let published: Date
    func replacingContent(title: String, html: String) -> Self {
        var copy = self; copy.title = title; copy.html = html
        return copy
    }
    init(url: URL, title: String, html: String) {
        key = "linked:" + UUID().uuidString
        hiddenText = ""; self.title = title; source = url.host ?? ""; self.url = url.absoluteString
        text = ""; self.html = html; feedHTML = ""; published = Date()
        contentRevision = ContentRules.revision
    }
    init(_ link: ArticleLink, content: CachedArticle) {
        hiddenText = link.hiddenText
        key = link.key; title = link.title; source = link.source; url = link.url
        text = content.text; html = content.html; feedHTML = content.feedHTML; published = link.published
        contentRevision = content.revision
    }
}

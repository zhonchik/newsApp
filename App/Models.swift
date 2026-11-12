import Foundation
import SwiftData

@Model final class Subscription {
    var id: UUID = UUID()
    var name: String = ""
    var address: String = ""
    var kind: String = "rss"
    var paused: Bool = false
    var hiddenText: String = ""
    var contentDefaultsApplied: Bool = false
    var created: Date = Date()
    init(name: String, address: String, kind: String) {
        self.name = name; self.address = address; self.kind = kind
        hiddenText = ContentRules.defaultHiddenText(address: address); contentDefaultsApplied = true
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
    var read: Bool = false
    var extracted: Bool = false
    var richExtracted: Bool = false
    var contentRevision: Int = 0
    init(item: RemoteArticle, subscription: Subscription) {
        key = subscription.id.uuidString + ":" + item.id
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

struct RemoteArticle: Decodable {
    let id: String
    let title: String
    let url: String
    let text: String
    let published: Date
    var html: String = ""
}

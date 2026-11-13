import Foundation
import SwiftData

/// Constructed in a detached task so SwiftData owns a background executor.
@ModelActor actor LibraryWorker {
    func migrateLibrary() throws {
            let positions = try modelContext.fetch(FetchDescriptor<ReadingPosition>())
            let all = try modelContext.fetch(FetchDescriptor<Article>()).sorted {
                if $0.queuePosition != $1.queuePosition { return $0.queuePosition < $1.queuePosition }
                if $0.published != $1.published { return $0.published < $1.published }
                return $0.key < $1.key
            }
            var known: [String: Article] = [:]
            var position = all.map(\.queuePosition).max() ?? 0
            var readPosition = all.map(\.readPosition).max() ?? 0
            for article in all {
                let identity = ArticleIdentity.key(url: article.url, fallback: article.key)
                if let kept = known[identity] {
                    kept.read = kept.read || article.read
                    if kept.read && kept.readPosition == 0 { readPosition += 1; kept.readPosition = readPosition }
                    if kept.html.isEmpty { kept.html = article.html }
                    if kept.feedHTML.isEmpty { kept.feedHTML = article.feedHTML }
                    for bookmark in positions where bookmark.articleKey == article.key { bookmark.articleKey = kept.key }
                    modelContext.delete(article)
                } else {
                    known[identity] = article
                    if article.read && article.readPosition == 0 { readPosition += 1; article.readPosition = readPosition }
                    if article.queuePosition == 0 { position += 1; article.queuePosition = position }
                }
            }
            try modelContext.save()
    }
    func importItems(_ items: [RemoteArticle], subscriptionID: UUID) throws {
                let active = try modelContext.fetch(FetchDescriptor<Subscription>())
                guard let subscription = active.first(where: { $0.id == subscriptionID }) else { return }
                let all = try modelContext.fetch(FetchDescriptor<Article>())
                var known = Dictionary(all.map { (ArticleIdentity.key(url: $0.url, fallback: $0.key), $0) }, uniquingKeysWith: { first, _ in first })
                var position = all.map(\.queuePosition).max() ?? 0
                for item in items.sorted(by: { ($0.published, $0.id) < ($1.published, $1.id) }) {
                    let key = ArticleIdentity.key(url: item.url, fallback: subscription.address + ":" + item.id)
                    if let existing = known[key] {
                        // Re-adding a feed reconnects its saved articles, including read history.
                        if !active.contains(where: { $0.id == existing.subscriptionID }) { existing.subscriptionID = subscription.id }
                        existing.feedHTML = item.html
                        if existing.html.isEmpty || subscription.kind == "telegram" { existing.html = item.html; existing.text = item.text }
                    } else {
                        let article = Article(item: item, subscription: subscription)
                        position += 1; article.queuePosition = position
                        modelContext.insert(article); known[key] = article
                    }
                }
                if !subscription.paused {
                    for article in known.values.filter({ $0.subscriptionID == subscription.id && $0.queued }).sorted(by: { $0.queuePosition < $1.queuePosition }) {
                        position += 1; article.queuePosition = position; article.queued = false
                    }
                }
                try modelContext.save()
    }
    func savePrepared(key: String, html: String, text: String) throws {
        let descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })
        guard let article = try modelContext.fetch(descriptor).first else { return }
        article.html = html; article.text = text
        article.extracted = true; article.richExtracted = true
        article.contentRevision = ContentRules.revision
        try modelContext.save()
    }
}

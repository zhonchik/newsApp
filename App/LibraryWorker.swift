#if SWIFT_PACKAGE
import ReaderContent
#endif
import Foundation
import SwiftData

/// Constructed in a detached task so SwiftData owns a background executor.
@ModelActor actor LibraryWorker {
    func migrateLibrary() throws {
            let modelContext = freshContext()
            let subscriptions = try modelContext.fetch(FetchDescriptor<Subscription>())
            for subscription in subscriptions {
                if !subscription.contentDefaultsApplied {
                    subscription.hiddenText = ContentRules.defaultHiddenText(address: subscription.address)
                    subscription.contentDefaultsApplied = true
                }
                if subscription.hiddenText == ContentRules.telegramNotice {
                    subscription.hiddenText += "\n" + ContentRules.telegramNoticeVariant
                }
            }
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
    private func freshContext() -> ModelContext {
        let context = ModelContext(modelContainer)
        context.autosaveEnabled = false
        return context
    }
    /// Read only the saved article on upgrade, before queue scans or migration.
    func launchDocument(cache: MediaCache = .shared) async throws -> ReaderDocument? {
        let context = freshContext()
        var positions = FetchDescriptor<ReadingPosition>(sortBy: [SortDescriptor(\.changed, order: .reverse)])
        positions.fetchLimit = 1
        let key = try context.fetch(positions).first?.articleKey ?? ""
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let article = try context.fetch(descriptor).first else { return nil }
        let subscriptionID = article.subscriptionID
        let subscription = try context.fetch(FetchDescriptor<Subscription>(predicate: #Predicate { $0.id == subscriptionID })).first
        let link = ArticleLink(article, hiddenText: subscription?.hiddenText ?? "")
        if let cached = await cache.article(link.key) { return ReaderDocument(link, content: cached) }
        if !article.text.isEmpty || !article.html.isEmpty || !article.feedHTML.isEmpty {
            return ReaderDocument(link, content: CachedArticle(text: article.text, html: article.html, feedHTML: article.feedHTML, revision: article.contentRevision))
        }
        return nil
    }
    func snapshot() throws -> LibrarySnapshot {
        let context = freshContext()
        let subscriptions = try context.fetch(FetchDescriptor<Subscription>(sortBy: [SortDescriptor(\.created)]))
        let all = try context.fetch(FetchDescriptor<Article>())
        var seen = Set<String>()
        let unique = all.filter { !$0.queued && seen.insert(ArticleIdentity.key(url: $0.url, fallback: $0.key)).inserted }
        let ordered = ReadingQueue.ordered(unique, isRead: { $0.read }, readPosition: { $0.readPosition }, queuePosition: { $0.queuePosition })
        let positions = try context.fetch(FetchDescriptor<ReadingPosition>(sortBy: [SortDescriptor(\.changed, order: .reverse)]))
        return LibrarySnapshot(articles: ordered.map { article in
            ArticleLink(article, hiddenText: subscriptions.first(where: { $0.id == article.subscriptionID })?.hiddenText ?? "")
        }, subscriptions: subscriptions.map { SubscriptionInfo(id: $0.id, name: $0.name, address: $0.address, kind: $0.kind) }, savedKey: positions.first?.articleKey ?? "")
    }
    func markOpened(_ key: String) throws {
        let context = freshContext()
        guard let article = try context.fetch(FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })).first else { return }
        if !article.read {
            var descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.readPosition, order: .reverse)])
            descriptor.fetchLimit = 1
            article.readPosition = (try context.fetch(descriptor).first?.readPosition ?? 0) + 1
            article.read = true
        }
        let positions = try context.fetch(FetchDescriptor<ReadingPosition>(sortBy: [SortDescriptor(\.changed, order: .reverse)]))
        if let position = positions.first { position.articleKey = key; position.changed = Date() }
        else { context.insert(ReadingPosition(articleKey: key)) }
        try context.save()
    }
    func legacyBody(_ key: String) throws -> CachedArticle? {
        var descriptor = FetchDescriptor<Article>(predicate: #Predicate { $0.key == key })
        descriptor.fetchLimit = 1
        guard let article = try freshContext().fetch(descriptor).first,
              !article.text.isEmpty || !article.html.isEmpty || !article.feedHTML.isEmpty else { return nil }
        return CachedArticle(text: article.text, html: article.html, feedHTML: article.feedHTML, revision: article.contentRevision)
    }

    /// Upgrade old installations without dropping the only offline copy first.
    func migrateContent(cache: MediaCache = .shared) async throws {
        var after: String?
        while true {
            try Task.checkCancellation()
            let context = freshContext()
            var descriptor = FetchDescriptor<Article>(sortBy: [SortDescriptor(\.key)])
            if let after {
                descriptor.predicate = #Predicate {
                    $0.key > after && ($0.html != "" || $0.text != "" || $0.feedHTML != "")
                }
            } else {
                descriptor.predicate = #Predicate { $0.html != "" || $0.text != "" || $0.feedHTML != "" }
            }
            descriptor.fetchLimit = 16
            let articles = try context.fetch(descriptor)
            guard !articles.isEmpty else { return }
            let bodies = articles.map { ($0.key, CachedArticle(text: $0.text, html: $0.html, feedHTML: $0.feedHTML, revision: $0.contentRevision)) }
            let stored = try await cache.migrateBatch(bodies)
            for article in articles where stored.contains(article.key) {
                article.text = ""; article.html = ""; article.feedHTML = ""
            }
            try context.save()
            after = articles.last?.key
            await Task.yield()
        }
    }

    func feedSubscriptions() throws -> [SubscriptionInfo] {
        try freshContext().fetch(FetchDescriptor<Subscription>()).map {
            SubscriptionInfo(id: $0.id, name: $0.name, address: $0.address, kind: $0.kind)
        }
    }

    func importItems(_ items: [RemoteArticle], subscriptionID: UUID, cache: MediaCache = .shared) async throws -> [ArticleLink] {
        let context = freshContext()
        let active = try context.fetch(FetchDescriptor<Subscription>())
        guard let subscription = active.first(where: { $0.id == subscriptionID }) else { return [] }
        let all = try context.fetch(FetchDescriptor<Article>())
        var known = Dictionary(all.map { (ArticleIdentity.key(url: $0.url, fallback: $0.key), $0) }, uniquingKeysWith: { first, _ in first })
        var position = all.map(\.queuePosition).max() ?? 0
        var result: [(ArticleLink, RemoteArticle)] = []
        for item in items.sorted(by: { ($0.published, $0.id) < ($1.published, $1.id) }) {
            let key = ArticleIdentity.key(url: item.url, fallback: subscription.address + ":" + item.id)
            let article: Article
            if let existing = known[key] {
                article = existing
                if !active.contains(where: { $0.id == article.subscriptionID }) { article.subscriptionID = subscription.id }
                article.title = item.title; article.source = subscription.name
            } else {
                article = Article(item: item, subscription: subscription)
                // Payload lives in the evictable local cache, never the permanent link record.
                article.text = ""; article.html = ""; article.feedHTML = ""
                position += 1; article.queuePosition = position
                context.insert(article); known[key] = article
            }
            result.append((ArticleLink(article, hiddenText: subscription.hiddenText), item))
        }
        if !subscription.paused {
            for article in known.values.filter({ $0.subscriptionID == subscription.id && $0.queued }).sorted(by: { $0.queuePosition < $1.queuePosition }) {
                position += 1; article.queuePosition = position; article.queued = false
            }
        }
        try context.save()
        for (link, item) in result {
            try Task.checkCancellation()
            let cached = await cache.article(link.key)
            if cached?.feedHTML != item.html {
                let revision = subscription.kind == "telegram" ? ContentRules.revision : 0
                try await cache.storeArticle(CachedArticle(text: item.text, html: item.html, feedHTML: item.html, revision: revision), key: link.key)
            }
        }
        return result.map { $0.0 }
    }
}

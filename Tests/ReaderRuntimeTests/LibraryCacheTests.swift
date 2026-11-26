import XCTest
import CryptoKit
import SwiftData
import ReaderContent
@testable import ReaderRuntime

final class LibraryCacheTests: XCTestCase {
    @MainActor func testInitialSnapshotSeesExistingLibraryWithoutQueryNotification() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        let subscription = Subscription(name: "Feed", address: "https://example.com/feed", kind: "rss")
        context.insert(subscription)
        let article = Article(item: item("first"), subscription: subscription)
        article.queuePosition = 1
        context.insert(article)
        context.insert(ReadingPosition(articleKey: article.key))
        try context.save()
        let worker = await Task.detached { LibraryWorker(modelContainer: container) }.value
        let snapshot = try await worker.snapshot()
        XCTAssertEqual(snapshot.articles.map(\.key), [article.key])
        XCTAssertEqual(snapshot.savedKey, article.key)
        try await worker.markOpened(article.key)
        let updated = try await worker.snapshot()
        XCTAssertTrue(updated.articles[0].read)
    }
    @MainActor func testImportBatchOrdersNewArrivalsWithoutReorderingOlderBatches() async throws {
        let container = try makeContainer()
        let context = ModelContext(container)
        for index in 0..<3 {
            let feed = Subscription(name: "Feed \(index)", address: "https://publisher.example/feed/\(index)", kind: "rss")
            context.insert(feed)
            let remote = RemoteArticle(id: "\(index)", title: "Story \(index)", url: "https://publisher.example/story/\(index)", text: "Saved", published: Date(timeIntervalSince1970: Double(3 - index) * 86400))
            let article = Article(item: remote, subscription: feed)
            article.queuePosition = index + 1
            context.insert(article)
        }
        try context.save()
        let worker = await Task.detached { LibraryWorker(modelContainer: container) }.value
        try await worker.orderNewImports(after: [])
        let snapshot = try await worker.snapshot()
        XCTAssertEqual(snapshot.articles.map(\.title), ["Story 2", "Story 1", "Story 0"])
        XCTAssertEqual(snapshot.unreadCount, 3)
        let oldest = try XCTUnwrap(snapshot.firstUnread)
        try await worker.markOpened(oldest)
        let next = try await worker.snapshot()
        XCTAssertEqual(next.articles.map(\.title), ["Story 2", "Story 1", "Story 0"])
        XCTAssertEqual(next.unreadCount, 2)
        XCTAssertEqual(next.firstUnread, next.articles[1].key)
        // A later import may contain older stories; it must still append after the existing queue.
        let feed = Subscription(name: "Later feed", address: "https://publisher.example/later", kind: "rss")
        context.insert(feed)
        for (index, time) in [500.0, 100.0, 100.0].enumerated() {
            let remote = RemoteArticle(id: "later-\(index)", title: "Later \(index)", url: "https://publisher.example/later/\(index)", text: "", published: Date(timeIntervalSince1970: time))
            let article = Article(item: remote, subscription: feed)
            article.queuePosition = index + 4; context.insert(article)
        }
        try context.save()
        try await worker.orderNewImports(after: Set(snapshot.articles.map(\.key)))
        let final = try await worker.snapshot()
        XCTAssertEqual(final.articles.map(\.title), ["Story 2", "Story 1", "Story 0", "Later 1", "Later 2", "Later 0"])
        XCTAssertEqual(final.unreadCount, 5)
    }

    @MainActor func testDiskLibraryRelaunchPreservesUnreadAndSavedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let schema = Schema([Article.self, Subscription.self, ReadingPosition.self])
        let configuration = ModelConfiguration(schema: schema, url: root.appendingPathComponent("library.store"), cloudKitDatabase: .none)
        var keys: [String] = []
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = ModelContext(container)
            let feed = Subscription(name: "Example", address: "https://publisher.example/feed", kind: "rss")
            context.insert(feed)
            for index in 0..<4 {
                let article = Article(item: item("saved-\(index)"), subscription: feed)
                article.queuePosition = index + 1
                article.read = index == 0
                article.readPosition = index == 0 ? 1 : 0
                keys.append(article.key); context.insert(article)
            }
            context.insert(ReadingPosition(articleKey: keys[0]))
            try context.save()
        }
        for _ in 0..<2 {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let worker = await Task.detached { LibraryWorker(modelContainer: container) }.value
            let cache = MediaCache(directory: root.appendingPathComponent("cache"))
            let saved = try await worker.launchDocument(cache: cache)
            XCTAssertEqual(saved?.key, keys[0])
            try await worker.migrateLibrary()
            try await worker.migrateContent(cache: cache)
            let snapshot = try await worker.snapshot()
            XCTAssertEqual(snapshot.articles.count, 4)
            XCTAssertEqual(snapshot.unreadCount, 3)
            XCTAssertEqual(snapshot.savedKey, keys[0])
            XCTAssertEqual(snapshot.articles.filter { !$0.read }.map(\.key), Array(keys.dropFirst()))
        }
    }

    @MainActor func testUpgradeCanDisplayLegacySavedBodyBeforeMigration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaCache(directory: root, limitBytes: 4096)
        let container = try makeContainer()
        let context = ModelContext(container)
        let subscription = Subscription(name: "Feed", address: "https://example.com/feed", kind: "rss")
        context.insert(subscription)
        let article = Article(item: item("upgrade"), subscription: subscription)
        article.html = "<figure><img src='https://example.com/original.jpg'></figure>"
        article.feedHTML = "<video src='https://example.com/clip.mp4'></video>"
        context.insert(article)
        context.insert(ReadingPosition(articleKey: article.key))
        try context.save()
        let worker = await Task.detached { LibraryWorker(modelContainer: container) }.value
        let launch = try await worker.launchDocument(cache: cache)
        XCTAssertEqual(launch?.key, article.key)
        XCTAssertEqual(launch?.text, "Article text")
        XCTAssertEqual(launch?.html, article.html)
        XCTAssertEqual(launch?.feedHTML, article.feedHTML)
        let restored = try await worker.launchDocument(restored: launch, cache: cache)
        XCTAssertEqual(restored, launch)
        let fresh = ModelContext(container)
        XCTAssertFalse(try XCTUnwrap(fresh.fetch(FetchDescriptor<Article>()).first).html.isEmpty)
        let size = try await cache.usage()
        XCTAssertEqual(size, 0, "Showing the saved article must not require a cache migration")
    }
    @MainActor func testMigrationAndEvictionKeepArticleLinksAndReadState() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaCache(directory: root, limitBytes: 1024)
        let container = try makeContainer()
        let context = ModelContext(container)
        let subscription = Subscription(name: "Feed", address: "https://example.com/feed", kind: "rss")
        context.insert(subscription)
        let article = Article(item: item("saved"), subscription: subscription)
        article.read = true; article.queuePosition = 1
        context.insert(article); try context.save()
        let key = article.key
        let worker = await Task.detached { LibraryWorker(modelContainer: container) }.value
        try await worker.migrateContent(cache: cache)
        let content = await cache.article(key)
        XCTAssertEqual(content?.text, "Article text")
        let fresh = ModelContext(container)
        let persisted = try XCTUnwrap(fresh.fetch(FetchDescriptor<Article>()).first)
        XCTAssertTrue(persisted.text.isEmpty)
        XCTAssertTrue(persisted.html.isEmpty)
        // A newer, large entry forces the old body out of the bounded cache.
        try await cache.storeArticle(CachedArticle(text: String(repeating: "x", count: 940), html: "", feedHTML: ""), key: "newer")
        let evicted = await cache.article(key)
        XCTAssertNil(evicted)
        let usage = try await cache.usage()
        XCTAssertLessThanOrEqual(usage, 1024)
        let snapshot = try await worker.snapshot()
        XCTAssertEqual(snapshot.articles.first?.url, "https://example.com/saved")
        XCTAssertEqual(snapshot.articles.first?.read, true)
    }
    @MainActor func testImportPublishesLinksAndCachesTextBeforeReturning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaCache(directory: root, limitBytes: 4096)
        let container = try makeContainer()
        let context = ModelContext(container)
        let subscription = Subscription(name: "Feed", address: "https://example.com/feed", kind: "rss")
        context.insert(subscription); try context.save()
        let worker = await Task.detached { LibraryWorker(modelContainer: container) }.value
        let links = try await worker.importItems([item("new")], subscriptionID: subscription.id, cache: cache)
        let link = try XCTUnwrap(links.first)
        let cached = await cache.article(link.key)
        XCTAssertEqual(cached?.text, "Article text")
        let snapshot = try await worker.snapshot()
        XCTAssertEqual(snapshot.articles.map(\.key), [link.key])
    }
    @MainActor func testOverlappingFeedImportsAcrossBatchesPreserveEnrichmentAndQueueCounts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaCache(directory: root, limitBytes: 64 * 1024)
        let container = try makeContainer()
        let context = ModelContext(container)
        let feed = Subscription(name: "Example", address: "https://example.com/rss", kind: "rss")
        context.insert(feed)
        try context.save()
        let worker = await Task.detached { LibraryWorker(modelContainer: container) }.value
        let items = (0..<34).map { item("story-\($0)") }
        _ = try await worker.importItems(items, subscriptionID: feed.id, cache: cache)
        let first = try await worker.snapshot()
        let saved = try XCTUnwrap(first.articles.first)
        let enriched = CachedArticle(text: "Offline copy", html: "<p>Full story</p>", feedHTML: items[0].html, revision: 42)
        try await cache.storeArticle(enriched, key: saved.key)
        _ = try await worker.importItems(items + [item("extra")], subscriptionID: feed.id, cache: cache)
        let updated = try await worker.snapshot(previousIndices: first.indexByKey)
        XCTAssertEqual(updated.articles.count, 35)
        XCTAssertEqual(updated.addedCount, 1)
        let cached = await cache.article(saved.key)
        XCTAssertEqual(cached, enriched)
    }

    @MainActor func testMigrationRetainsOfflineBodyWhenReplacementDoesNotFit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = MediaCache(directory: root, limitBytes: 8)
        let container = try makeContainer()
        let context = ModelContext(container)
        let subscription = Subscription(name: "Feed", address: "test", kind: "rss")
        context.insert(subscription)
        context.insert(Article(item: item("large"), subscription: subscription))
        try context.save()
        let worker = await Task.detached { LibraryWorker(modelContainer: container) }.value
        try await worker.migrateContent(cache: cache)
        let restored = try ModelContext(container).fetch(FetchDescriptor<Article>())
        XCTAssertEqual(restored.first?.text, "Article text")
    }

    @MainActor func testFormattedBodySurvivesRelaunchAndRespectsChangedInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let subscription = Subscription(name: "Feed", address: "test", kind: "rss")
        let article = Article(item: item("formatted"), subscription: subscription)
        let link = ArticleLink(article, hiddenText: "")
        let image = "https://example.com/image.jpg"
        let paragraphs = String(repeating: "<p>First <strong>secret</strong> paragraph.</p>", count: 200)
        let content = CachedArticle(text: "", html: paragraphs + "<img src='\(image)'>", feedHTML: "")
        let doc = ReaderDocument(link, content: content)
        let writer = MediaCache(directory: root)
        let coldStart = ProcessInfo.processInfo.systemUptime
        let first = try await writer.formattedBody(doc, hiddenText: "")
        let coldMS = Int((ProcessInfo.processInfo.systemUptime - coldStart) * 1000)
        XCTAssertFalse(first.reused)
        XCTAssertTrue(first.html.contains("data-reader-src"))
        try await writer.saveFormattedBody()
        let reader = MediaCache(directory: root)
        let warmStart = ProcessInfo.processInfo.systemUptime
        let next = try await reader.formattedBody(doc, hiddenText: "")
        let warmMS = Int((ProcessInfo.processInfo.systemUptime - warmStart) * 1000)
        print("Formatted article body (200 paragraphs): built \(coldMS) ms, restored \(warmMS) ms")
        XCTAssertTrue(next.reused)
        XCTAssertEqual(next.html, first.html)
        let name = SHA256.hash(data: Data(image.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(name)
        try Data([1]).write(to: file)
        try JSONEncoder().encode(MediaCache.Entry(file: file, mime: "image/jpeg", size: 1)).write(to: file.appendingPathExtension("json"))
        let localImage = try await reader.formattedBody(doc, hiddenText: "")
        XCTAssertFalse(localImage.reused)
        XCTAssertFalse(localImage.html.contains("data-reader-src"))
        XCTAssertTrue(localImage.html.contains("src=\"reader-media:"))
        let filtered = try await reader.formattedBody(doc, hiddenText: "secret")
        XCTAssertFalse(filtered.reused)
        XCTAssertFalse(filtered.html.contains("secret"))
        let changed = ReaderDocument(link, content: CachedArticle(text: "Second", html: "", feedHTML: ""))
        let updated = try await reader.formattedBody(changed, hiddenText: "secret")
        XCTAssertFalse(updated.reused)
        XCTAssertTrue(updated.html.contains("Second"))
    }

    @MainActor func testQueueIndexTracksSelectionUnreadAndAddedStories() {
        let subscription = Subscription(name: "Feed", address: "test", kind: "rss")
        let links = ["one", "two", "three"].map { id in
            let article = Article(item: item(id), subscription: subscription)
            article.read = id == "one"
            return ArticleLink(article, hiddenText: "")
        }
        let queue = LibrarySnapshot(articles: links, subscriptions: [], savedKey: links[1].key, previousIndices: [links[0].key: 0])
        XCTAssertEqual(queue.addedCount, 2)
        XCTAssertEqual(queue.unreadCount, 2)
        XCTAssertEqual(queue.firstUnread, links[1].key)
        XCTAssertEqual(queue.indexByKey[links[2].key], 2)
        XCTAssertEqual(queue.restoredSelection(links[0].key), links[0].key)
        XCTAssertEqual(queue.restoredSelection("missing"), links[1].key)
    }

    @MainActor private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Article.self, Subscription.self, ReadingPosition.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    private func item(_ id: String) -> RemoteArticle {
        RemoteArticle(id: id, title: "Article", url: "https://example.com/" + id, text: "Article text", published: Date(), html: "<p>Article text</p>")
    }
}

import XCTest
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
    @MainActor private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Article.self, Subscription.self, ReadingPosition.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    private func item(_ id: String) -> RemoteArticle {
        RemoteArticle(id: id, title: "Article", url: "https://example.com/" + id, text: "Article text", published: Date(), html: "<p>Article text</p>")
    }
}

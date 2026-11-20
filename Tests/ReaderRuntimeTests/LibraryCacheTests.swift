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

    @MainActor private func makeContainer() throws -> ModelContainer {
        let schema = Schema([Article.self, Subscription.self, ReadingPosition.self])
        return try ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    private func item(_ id: String) -> RemoteArticle {
        RemoteArticle(id: id, title: "Article", url: "https://example.com/" + id, text: "Article text", published: Date(), html: "<p>Article text</p>")
    }
}

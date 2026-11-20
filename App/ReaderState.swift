import SwiftUI
import SwiftData

@MainActor final class ReaderState: ObservableObject {
    @Published var articles: [ArticleLink] = []
    @Published var subscriptions: [SubscriptionInfo] = []
    @Published var selection = ""
    @Published var document: ReaderDocument?
    @Published var starting = true
    @Published var pageVisible = false
    @Published var loadingArticle = false
    @Published var updating = false
    @Published var reloadingArticle = false
    var isUpdating: Bool { updating || reloadingArticle }
    @Published var updateFailed = false
    @Published var updateMessage = ""
    @Published var articleError: String?
    @Published var startupError: String?
    @Published var renderVersion = 0
    private var worker: LibraryWorker?
    private let preparation = ArticlePreparation()
    private let service = FeedService()
    private var lastRefresh = Date.distantPast
    private var opening = false
    private var firstPageDisplayed = false
    private var backgroundStarted = false
    private var maintenance: Task<Void, Never>?
    private var cacheWarmup: Task<Void, Never>?
    private var loadingKey: String?
    var current: ArticleLink? { articles.first { $0.key == selection } }
    var unreadCount: Int { articles.filter { !$0.read }.count }

    func start(library: LibraryContainer) async {
        guard worker == nil, !opening else { return }
        opening = true; starting = true; startupError = nil
        defer { opening = false; starting = false }
        do {
            let background = try await library.worker()
            worker = background
            // Publish the saved body before any all-library scan or migration.
            if let cached = try await background.launchDocument() {
                document = cached; selection = cached.key
            }
            try await reloadSnapshot()
            starting = false
            if let current, document?.key == current.key { try? await MediaCache.shared.remember(current) }
            if firstPageDisplayed || current == nil || articleError != nil { beginBackgroundWork() }
        } catch {
            startupError = error.localizedDescription
            if articles.isEmpty { worker = nil }
        }
    }
    func pageDidDisplay() {
        pageVisible = true
        firstPageDisplayed = true
        if !starting { beginBackgroundWork() }
    }
    func pageFailed(_ message: String) {
        articleError = message
        if !starting { beginBackgroundWork() }
    }
    func retryPage() { articleError = nil; renderVersion += 1 }
    private func beginBackgroundWork() {
        guard let worker, !backgroundStarted else { return }
        backgroundStarted = true
        maintenance = Task(priority: .utility) { [weak self] in
            do {
                try await worker.migrateLibrary()
                try await worker.migrateContent()
            } catch { self?.startupError = error.localizedDescription }
            try? await self?.reloadSnapshot()
            await self?.refresh(force: true)
        }
    }
    func reloadSnapshot() async throws {
        guard let worker else { return }
        let snapshot = try await worker.snapshot()
        articles = snapshot.articles; subscriptions = snapshot.subscriptions
        selection = ReaderSelection.restored(keys: articles.map(\.key), current: selection, saved: snapshot.savedKey)
        if selection.isEmpty { document = nil }
    }
    func loadSelected() async {
        guard let worker, let link = current, loadingKey != link.key else { return }
        let key = link.key
        loadingKey = key
        loadingArticle = true; articleError = nil
        defer {
            if loadingKey == key { loadingKey = nil }
            if selection == key { loadingArticle = false }
        }
        do {
            let content: CachedArticle
            if let cached = await MediaCache.shared.article(key) { content = cached }
            else {
                try await worker.migrateContent(key: key)
                if let migrated = await MediaCache.shared.article(key) { content = migrated }
                else { content = try await preparation.prepare(link) }
            }
            guard !Task.isCancelled, selection == key else { return }
            document = ReaderDocument(link, content: content)
            try? await MediaCache.shared.remember(link)
            try await worker.markOpened(key)
            try await reloadSnapshot()
            if backgroundStarted, selection == articles.last?.key { await refresh() }
        } catch is CancellationError { }
        catch { if selection == key { pageFailed(error.localizedDescription) } }
    }
    func move(_ offset: Int) {
        guard let index = articles.firstIndex(where: { $0.key == selection }), articles.indices.contains(index + offset) else {
            if offset > 0 { Task { await refresh() } }
            return
        }
        selection = articles[index + offset].key
    }
    func refresh(force: Bool = false) async {
        guard let worker, !starting, backgroundStarted, !updating, force || Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        updating = true; updateFailed = false; lastRefresh = Date(); updateMessage = "Updating subscriptions"
        defer { updating = false }
        var outcome = RefreshOutcome()
        var toCache: [ArticleLink] = []
        do { try await reloadSnapshot() } catch { outcome.errors.append(error.localizedDescription) }
        for subscription in subscriptions {
            do {
                try Task.checkCancellation()
                let previous = Set(articles.map(\.key))
                let items = try await service.itemsWithRetry(address: subscription.address, kind: subscription.kind)
                let links = try await worker.importItems(items, subscriptionID: subscription.id)
                try await reloadSnapshot()
                outcome.newArticles += articles.filter { !previous.contains($0.key) }.count
                toCache.append(contentsOf: links)
            } catch is CancellationError { return }
            catch { outcome.errors.append("\(subscription.name): \(error.localizedDescription)") }
        }
        updateFailed = outcome.failed; updateMessage = outcome.message
        // Optional media failures do not turn a successful feed update red.
        // Cache work is lower priority and never gates initial article display.
        cacheWarmup?.cancel()
        let preparation = preparation
        let linksToCache = toCache
        cacheWarmup = Task.detached(priority: .utility) {
            for link in linksToCache {
                guard !Task.isCancelled else { return }
                do {
                    let content = try await preparation.prepare(link)
                    try await MediaCache.shared.prefetchImages(content.html, feed: content.feedHTML, baseURL: link.url)
                } catch { /* Missing media is retried when selected or refreshed. */ }
            }
        }
    }
    func reloadArticle() async {
        guard let link = current, !reloadingArticle else { return }
        reloadingArticle = true
        defer { reloadingArticle = false }
        let key = link.key
        articleError = nil
        do {
            let content = try await preparation.prepare(link, force: true)
            var imageError: Error?
            do { try await MediaCache.shared.prefetchImages(content.html, feed: content.feedHTML, baseURL: link.url, force: true) }
            catch { imageError = error }
            guard selection == key, !Task.isCancelled else { return }
            document = ReaderDocument(link, content: content)
            renderVersion += 1
            updateFailed = false
            updateMessage = imageError == nil ? "Article updated" : "Article updated · some images are unavailable"
        } catch {
            updateFailed = true; updateMessage = error.localizedDescription
            // Keep the cached page usable when a forced reload fails.
            if document?.key != key { articleError = error.localizedDescription }
        }
    }
    func settingsClosed() async {
        try? await MediaCache.shared.trim()
        await refresh(force: true)
    }
}

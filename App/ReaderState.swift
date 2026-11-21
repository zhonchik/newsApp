import SwiftUI
import SwiftData
import os

@MainActor final class ReaderState: ObservableObject {
    @Published private var queue = LibrarySnapshot(articles: [], subscriptions: [], savedKey: "")
    var articles: [ArticleLink] { queue.articles }
    var subscriptions: [SubscriptionInfo] { queue.subscriptions }
    @Published var selection = ""
    @Published var document: ReaderDocument?
    @Published var starting = true
    @Published var pageVisible = false
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
    private var loadingInitialQueue = false
    private var displayedKey: String?
    private var backgroundStarted = false
    private var maintenance: Task<Void, Never>?
    private var cacheWarmup: Task<Void, Never>?
    private var loadRequest: UUID?
    var current: ArticleLink? { queue.indexByKey[selection].map { articles[$0] } }
    var unreadCount: Int { queue.unreadCount }

    var firstUnread: String? { queue.firstUnread }

    func start(library: LibraryContainer) async {
        guard worker == nil, !opening else { return }
        opening = true; starting = true; startupError = nil
        defer { opening = false }
        do {
            let background = try await library.worker()
            worker = background
            // Publish the saved body before any all-library scan or migration.
            if let cached = try await background.launchDocument(restored: library.launchDocument) {
                LaunchMetrics.mark("Saved database article available")
                document = cached; selection = cached.key
            }
            if let document, displayedKey != document.key, articleError == nil { return }
            await loadInitialQueue()
        } catch {
            startupError = error.localizedDescription
            worker = nil
            starting = false
        }
    }

    private func loadInitialQueue() async {
        guard starting, worker != nil, !loadingInitialQueue else { return }
        loadingInitialQueue = true
        defer { loadingInitialQueue = false }
        do {
            LaunchMetrics.mark("Queue lookup started")
            try await reloadSnapshot()
            LaunchMetrics.mark("Queue available")
            starting = false
            if let current, document?.key == current.key { try? await MediaCache.shared.remember(current) }
            if displayedKey == selection || current == nil || articleError != nil { beginBackgroundWork() }
            if let current { await refreshStaleArticle(current) }
        } catch {
            startupError = error.localizedDescription
            starting = false
            if articles.isEmpty { worker = nil }
        }
    }
    func pageDidDisplay(_ key: String) {
        pageVisible = true
        displayedKey = key
        if starting && key == document?.key {
            Task { await loadInitialQueue() }
        } else if !starting && key == selection { beginBackgroundWork() }
    }
    func pageFailed(_ message: String) {
        articleError = message
        if starting && document != nil { Task { await loadInitialQueue() } }
        else if !starting { beginBackgroundWork() }
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
    @discardableResult
    func reloadSnapshot(previousIndices: [String: Int]? = nil) async throws -> Int {
        guard let worker else { return 0 }
        let interval = OSSignpostID(log: LaunchMetrics.log)
        os_signpost(.begin, log: LaunchMetrics.log, name: "Queue snapshot", signpostID: interval)
        defer { os_signpost(.end, log: LaunchMetrics.log, name: "Queue snapshot", signpostID: interval) }
        let snapshot = try await worker.snapshot(previousIndices: previousIndices)
        queue = snapshot
        let restored = snapshot.restoredSelection(selection)
        if selection != restored { selection = restored }
        if selection.isEmpty { document = nil }
        return snapshot.addedCount
    }
    func loadSelected() async {
        guard let worker, let link = current else { return }
        let key = link.key
        let request = UUID()
        loadRequest = request
        articleError = nil
        defer {
            if loadRequest == request { loadRequest = nil }
        }
        do {
            let content: CachedArticle
            if let cached = await MediaCache.shared.article(key) { content = cached }
            else if let legacy = try await worker.legacyBody(key) { content = legacy }
            else {
                LaunchMetrics.mark("Selected body missing locally; publisher fetch started")
                content = try await preparation.prepare(link)
                LaunchMetrics.mark("Publisher body available")
            }
            guard !Task.isCancelled, selection == key, loadRequest == request else { return }
            document = ReaderDocument(link, content: content)
            try? await MediaCache.shared.remember(link)
            guard !Task.isCancelled, selection == key, loadRequest == request else { return }
            try await worker.markOpened(key)
            try await reloadSnapshot()
            await refreshStaleArticle(link)
            if backgroundStarted, selection == articles.last?.key { await refresh() }
        } catch is CancellationError { }
        catch { if !Task.isCancelled && loadRequest == request && selection == key { pageFailed(error.localizedDescription) } }
    }

    private func refreshStaleArticle(_ link: ArticleLink) async {
        guard !ContentRules.isTelegram(link.url), let displayed = document,
              displayed.key == link.key, (1..<ContentRules.revision).contains(displayed.contentRevision) else { return }
        guard let content = try? await preparation.prepare(link), content.revision >= ContentRules.revision,
              !Task.isCancelled, selection == link.key, document == displayed else { return }
        document = ReaderDocument(link, content: content)
    }
    func move(_ offset: Int) {
        guard let index = queue.indexByKey[selection], articles.indices.contains(index + offset) else {
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
        let previous = queue.indexByKey
        var needsSnapshot = false
        var mayPublishEarly = articles.isEmpty
        for subscription in subscriptions {
            do {
                try Task.checkCancellation()
                let items = try await service.itemsWithRetry(address: subscription.address, kind: subscription.kind)
                needsSnapshot = true
                let links: [ArticleLink]
                do {
                    let interval = OSSignpostID(log: LaunchMetrics.log)
                    os_signpost(.begin, log: LaunchMetrics.log, name: "Feed import", signpostID: interval)
                    defer { os_signpost(.end, log: LaunchMetrics.log, name: "Feed import", signpostID: interval) }
                    links = try await worker.importItems(items, subscriptionID: subscription.id)
                }
                toCache.append(contentsOf: links)
                // Populate an empty reader promptly. Otherwise keep the current
                // article stable until imports for this refresh have finished.
                if mayPublishEarly && !links.isEmpty {
                    outcome.newArticles = try await reloadSnapshot(previousIndices: previous)
                    needsSnapshot = false
                    mayPublishEarly = false
                }
            } catch is CancellationError { break }
            catch { outcome.errors.append("\(subscription.name): \(error.localizedDescription)") }
        }
        if needsSnapshot {
            do { outcome.newArticles = try await reloadSnapshot(previousIndices: previous) }
            catch { outcome.errors.append(error.localizedDescription) }
        }
        guard !Task.isCancelled else { return }
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

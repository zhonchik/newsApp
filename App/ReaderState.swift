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
    @Published private(set) var queueLoaded = false
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

    @Published private(set) var history = ReaderHistory()
    @Published var openingLink = false
    @Published var linkError: String?
    private var linkTask: Task<Void, Never>?
    private var historySave: Task<Void, Never>?
    private var navigationID = UUID()
    private static var historyFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Current/reader-history.json")
    }
    var canGoHome: Bool { history.canGoHome }
    func scrollOffset(for key: String) -> Double {
        history.entries.first(where: { $0.document.key == key })?.offset ?? 0
    }
    init() {
        if let data = try? Data(contentsOf: Self.historyFile),
           let saved = try? JSONDecoder().decode(ReaderHistory.self, from: data), let root = saved.root {
            history = saved; document = saved.current?.document; selection = root.key
        }
    }
    func saveHistory() {
        historySave?.cancel()
        do {
            let file = Self.historyFile
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(history).write(to: file, options: .atomic)
        } catch { updateFailed = true; updateMessage = "Could not save reading position: " + error.localizedDescription }
    }
    func recordScroll(key: String, offset: Double) {
        guard history.entries.contains(where: { $0.document.key == key }) else { return }
        history.scroll(key: key, offset: offset)
        historySave?.cancel()
        historySave = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            self?.saveHistory()
        }
    }
    private func cancelLink() {
        navigationID = UUID(); linkTask?.cancel(); linkTask = nil; openingLink = false
    }
    func home() {
        cancelLink(); history.home(); document = history.current?.document
        articleError = nil; saveHistory()
    }
    func openLink(_ url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              let original = document else { return }
        if history.root == nil { history.select(original) }
        cancelLink(); loadRequest = nil
        let request = navigationID
        openingLink = true; articleError = nil; linkError = nil
        linkTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await service.articleContent(url: url.absoluteString)
                guard !Task.isCancelled, navigationID == request, document?.key == original.key else { return }
                guard !result.html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw URLError(.cannotParseResponse) }
                let linked = ReaderDocument(url: url, title: result.title, html: result.html)
                history.push(linked); document = linked; openingLink = false; saveHistory()
            } catch {
                guard !Task.isCancelled, navigationID == request else { return }
                openingLink = false
                linkError = error.localizedDescription
            }
        }
    }

    func start(library: LibraryContainer) async {
        guard worker == nil, !opening else { return }
        opening = true; starting = true; startupError = nil
        defer { opening = false }
        do {
            let background = try await library.worker()
            worker = background
            // Publish the saved body before any all-library scan or migration.
            if document == nil, let cached = try await background.launchDocument(restored: library.launchDocument) {
                LaunchMetrics.mark("Saved database article available")
                document = cached; selection = cached.key; history.select(cached)
            }
            // Queue restoration must not depend on a view firing onAppear again.
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
            beginBackgroundWork()
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
        } else if !starting && key == document?.key { beginBackgroundWork() }
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
        queueLoaded = true
        // A temporarily empty/incomplete store (for example during cloud restoration)
        // must not discard the only saved copy of the active reading session.
        let restored = history.restoredSelection(selection, snapshot: snapshot)
        if selection != restored { selection = restored }
        if selection.isEmpty { document = nil }
        return snapshot.addedCount
    }
    func loadSelected() async {
        guard let worker, let link = current else { return }
        if history.root?.key == link.key, history.canGoHome {
            document = history.current?.document
            return
        }
        cancelLink()
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
            history.select(document!); saveHistory()
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
        history.update(document!); saveHistory()
    }
    func move(_ offset: Int) {
        cancelLink()
        if offset < 0 && history.back() {
            document = history.current?.document ?? document
            articleError = nil; saveHistory()
            return
        }
        home()
        guard let index = queue.indexByKey[selection] else {
            if offset > 0, let key = firstUnread ?? articles.first?.key { selection = key }
            else if offset > 0 { Task { await refresh() } }
            return
        }
        guard articles.indices.contains(index + offset) else {
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
            } catch is CancellationError { break }
            catch { outcome.errors.append("\(subscription.name): \(error.localizedDescription)") }
        }
        if needsSnapshot {
            do {
                try await worker.orderNewImports(after: Set(previous.keys))
                outcome.newArticles = try await reloadSnapshot(previousIndices: previous)
            }
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
        if history.canGoHome, let displayed = document, let url = URL(string: displayed.url) {
            guard !reloadingArticle else { return }
            reloadingArticle = true
            defer { reloadingArticle = false }
            do {
                let result = try await service.articleContent(url: url.absoluteString)
                guard document?.key == displayed.key, !Task.isCancelled else { return }
                let refreshed = displayed.replacingContent(title: result.title, html: result.html)
                history.update(refreshed); document = refreshed; renderVersion += 1; saveHistory()
            } catch { updateFailed = true; updateMessage = error.localizedDescription }
            return
        }
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
            history.update(document!); saveHistory()
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

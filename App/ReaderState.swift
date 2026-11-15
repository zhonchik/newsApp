import SwiftUI
import SwiftData

@MainActor final class ReaderState: ObservableObject {
    @Published var articles: [ArticleLink] = []
    @Published var subscriptions: [SubscriptionInfo] = []
    @Published var selection = ""
    @Published var document: ReaderDocument?
    @Published var starting = true
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
    var current: ArticleLink? { articles.first { $0.key == selection } }
    var unreadCount: Int { articles.filter { !$0.read }.count }

    func start(container: ModelContainer) async {
        guard worker == nil, !opening else { return }
        opening = true; starting = true; startupError = nil
        defer { opening = false; starting = false }
        let background = await Task.detached(priority: .utility) { LibraryWorker(modelContainer: container) }.value
        worker = background
        do {
            // Fetch an explicit snapshot; do not wait for @Query to merge another context.
            try await reloadSnapshot()
            starting = false
            try await background.migrateLibrary()
            try await reloadSnapshot()
            try await background.migrateContent()
            await refresh(force: true)
        } catch {
            startupError = error.localizedDescription
            if articles.isEmpty { worker = nil }
        }
    }
    func reloadSnapshot() async throws {
        guard let worker else { return }
        let snapshot = try await worker.snapshot()
        articles = snapshot.articles; subscriptions = snapshot.subscriptions
        selection = ReaderSelection.restored(keys: articles.map(\.key), current: selection, saved: snapshot.savedKey)
    }
    func loadSelected() async {
        guard let worker, let link = current else { return }
        let key = link.key
        loadingArticle = true; articleError = nil
        defer { if selection == key { loadingArticle = false } }
        do {
            try await worker.migrateContent(key: key)
            let content: CachedArticle
            if let cached = await MediaCache.shared.article(key) { content = cached }
            else { content = try await preparation.prepare(link) }
            guard !Task.isCancelled, selection == key else { return }
            document = ReaderDocument(link, content: content)
            try await worker.markOpened(key)
            try await reloadSnapshot()
            if selection == articles.last?.key { await refresh() }
        } catch is CancellationError { }
        catch { if selection == key { articleError = error.localizedDescription } }
    }
    func move(_ offset: Int) {
        guard let index = articles.firstIndex(where: { $0.key == selection }), articles.indices.contains(index + offset) else {
            if offset > 0 { Task { await refresh() } }
            return
        }
        selection = articles[index + offset].key
    }
    func refresh(force: Bool = false) async {
        guard let worker, !updating, force || Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        updating = true; lastRefresh = Date(); updateMessage = "Updating subscriptions"
        defer { updating = false }
        var failures: [String] = []
        do { try await reloadSnapshot() } catch { failures.append(error.localizedDescription) }
        for subscription in subscriptions {
            do {
                try Task.checkCancellation()
                let items = try await service.itemsWithRetry(address: subscription.address, kind: subscription.kind)
                let links = try await worker.importItems(items, subscriptionID: subscription.id)
                try await reloadSnapshot()
                for link in links {
                    try Task.checkCancellation()
                    do {
                        let content = try await preparation.prepare(link)
                        try await MediaCache.shared.prefetchImages(content.html + content.feedHTML, baseURL: link.url)
                    } catch is CancellationError { throw CancellationError() }
                    catch { failures.append("\(link.source): \(error.localizedDescription)") }
                }
            } catch is CancellationError { return }
            catch { failures.append("\(subscription.name): \(error.localizedDescription)") }
        }
        updateFailed = !failures.isEmpty
        updateMessage = failures.isEmpty ? "Subscriptions updated" : failures.joined(separator: "\n")
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
            do { try await MediaCache.shared.prefetchImages(content.html + content.feedHTML, baseURL: link.url, force: true) }
            catch { imageError = error }
            guard selection == key, !Task.isCancelled else { return }
            document = ReaderDocument(link, content: content)
            renderVersion += 1
            updateFailed = imageError != nil; updateMessage = imageError?.localizedDescription ?? "Article updated"
        } catch {
            updateFailed = true; updateMessage = error.localizedDescription
            // Keep the cached page usable when a forced reload fails.
            if document?.key != key { articleError = error.localizedDescription }
        }
    }
    func settingsClosed() async {
        do { try await reloadSnapshot(); try await MediaCache.shared.trim() }
        catch { updateFailed = true; updateMessage = error.localizedDescription }
        await refresh(force: true)
    }
}

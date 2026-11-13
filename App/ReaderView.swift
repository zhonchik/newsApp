import SwiftUI
import SwiftData
import SwiftSoup

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(sort: [SortDescriptor(\Article.queuePosition), SortDescriptor(\Article.published), SortDescriptor(\Article.key)]) private var articles: [Article]
    @Query private var subscriptions: [Subscription]
    @Query(sort: \ReadingPosition.changed, order: .reverse) private var positions: [ReadingPosition]
    @State private var preparation = ArticlePreparation()
    @State private var selected = ""
    @State private var prepared: ReaderDocument?
    @State private var showSubscriptions = false
    @State private var refreshing = false
    @State private var initialized = false
    @State private var preparationGeneration = 0
    @State private var lastRefresh = Date.distantPast
    @State private var updateStatus: String?
    @State private var errorMessage: String?
    @State private var worker: LibraryWorker?
    @State private var feed: [Article] = []
    @State private var identities: [String: String] = [:]
    private func rebuildFeed() {
        var seen = Set<String>()
        var cachedIdentities = identities
        let unique = articles.filter { article in
            guard !article.queued else { return false }
            let lookup = article.url + "|" + article.key
            let identity = cachedIdentities[lookup] ?? ArticleIdentity.key(url: article.url, fallback: article.key)
            cachedIdentities[lookup] = identity
            return seen.insert(identity).inserted
        }
        identities = cachedIdentities
        feed = ReadingQueue.ordered(unique, isRead: { $0.read }, readPosition: { $0.readPosition }, queuePosition: { $0.queuePosition })
    }
    private var current: Article? { feed.first { $0.key == selected } }
    private var visibleDocument: ReaderDocument? {
        if let prepared, prepared.key == selected { return prepared }
        return current.map { ReaderDocument($0) }
    }
    private var index: Int { feed.firstIndex { $0.key == selected } ?? 0 }
    private var hiddenText: String { subscriptions.first { $0.id == current?.subscriptionID }?.hiddenText ?? "" }
    private let service = FeedService()
    var body: some View {
        NavigationStack {
            readerContent
            .toolbar { readerToolbar }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            #endif
            .sheet(isPresented: $showSubscriptions) { SubscriptionsView() }
            .alert("Couldn't save library", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task {
                guard !initialized else { return }
                for subscription in subscriptions where !subscription.contentDefaultsApplied {
                    subscription.hiddenText = ContentRules.defaultHiddenText(address: subscription.address)
                    subscription.contentDefaultsApplied = true
                }
                for subscription in subscriptions where subscription.hiddenText == ContentRules.telegramNotice {
                    subscription.hiddenText = ContentRules.telegramNotice + "\n" + ContentRules.telegramNoticeVariant
                }
                save()
                let container = context.container
                let background = await Task.detached(priority: .utility) { LibraryWorker(modelContainer: container) }.value
                worker = background
                do { try await background.migrateLibrary() } catch { errorMessage = error.localizedDescription }
                rebuildFeed(); restore(); initialized = true
                await refresh(force: true)
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    if phase == .active { await refresh() }
                }
            }
            .task(id: selected) { showCurrent() }
            .task(id: preparationKey) { await prepareInBackground() }
            .onChange(of: showSubscriptions) { _, visible in if !visible { Task { await refresh(force: true) } } }
            .onChange(of: selected) { _, key in
                guard !key.isEmpty else { return }
                if let position = positions.first { position.articleKey = key; position.changed = Date() }
                else { context.insert(ReadingPosition(articleKey: key)) }
                save()
                if key == feed.last?.key { Task { await refresh() } }
            }
            .onChange(of: phase) { _, value in if value == .active && initialized { Task { await refresh() } } }
            .onChange(of: articles.map { QueueStamp(key: $0.key, queued: $0.queued, read: $0.read, queue: $0.queuePosition, history: $0.readPosition) }, initial: true) { _, _ in rebuildFeed(); restore() }
            .onChange(of: feed.map(\.key)) { _, _ in restore() }
        }.tint(Color(red: 0.14, green: 0.54, blue: 0.51))
    }
    @ViewBuilder private var readerContent: some View {
                if let document = visibleDocument {
                    ArticleWebView(article: document, hiddenText: hiddenText, move: move)
                        .accessibilityAction(named: "Next article") { move(1) }
                        .accessibilityAction(named: "Previous article") { move(-1) }

                } else {
                    ContentUnavailableView {
                        Label("A little more perspective.", systemImage: "text.page")
                    } description: {
                        Text(subscriptions.isEmpty ? "Add an RSS feed or public Telegram channel to start your reading queue." : "Stories update automatically. Paused subscriptions keep new stories queued until you resume.")
                    } actions: {
                        Button("Manage subscriptions") { showSubscriptions = true }.buttonStyle(.borderedProminent)
                    }
                }
    }
    @ToolbarContentBuilder private var readerToolbar: some ToolbarContent {
                ToolbarItem(placement: .principal) {
                    Text("\(feed.filter { !$0.read }.count) unread").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                ToolbarItem {
                    Button {
                        if let unread = feed.first(where: { !$0.read }) { selected = unread.key }
                    } label: { Label("Go to first unread", systemImage: "forward.end.fill") }
                    .disabled(!feed.contains(where: { !$0.read }))
                }
                ToolbarItem {
                    Button { showSubscriptions = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                }
                if let updateStatus {
                    ToolbarItem { Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").help(updateStatus).accessibilityLabel(updateStatus) }
                }
    }
    private var preparationKey: String {
        let keys = feed.map { $0.key }.joined(separator: "|")
        return "\(selected)|\(keys)|\(preparationGeneration)|\(phase == .active)"
    }
    @MainActor private func prepareInBackground() async {
        var candidates: [Article] = []
        if let article = current { candidates.append(article) }
        candidates.append(contentsOf: feed.filter { !$0.read && $0.key != selected })
        candidates.append(contentsOf: feed.filter { $0.read && $0.key != selected })
        for article in candidates {
            guard !Task.isCancelled, phase == .active else { return }
            if let worker { await preparation.prepare(article, worker: worker) }
        }
    }
    private func restore() {
        if feed.contains(where: { $0.key == selected }) { return }
        let saved = positions.first?.articleKey ?? ""
        selected = feed.contains(where: { $0.key == saved }) ? saved : (feed.first?.key ?? "")
    }
    private func move(_ offset: Int) {
        let next = index + offset
        guard feed.indices.contains(next) else {
            if offset > 0 { Task { await refresh() } }
            return
        }
        selected = feed[next].key
    }
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
    @MainActor private func refresh(force: Bool = false) async {
        guard !refreshing, !subscriptions.isEmpty, force || Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        refreshing = true; lastRefresh = Date()
        defer { refreshing = false }
        guard let worker else { return }
        do { try await worker.migrateLibrary() } catch { errorMessage = error.localizedDescription }
        var failures: [String] = []
        for subscription in subscriptions {
            do {
                let items = try await service.itemsWithRetry(address: subscription.address, kind: subscription.kind)
                guard !Task.isCancelled else { return }
                try await worker.importItems(items, subscriptionID: subscription.id)
            } catch is CancellationError { return }
            catch { failures.append("\(subscription.name): \(error.localizedDescription)") }
        }
        preparationGeneration += 1
        updateStatus = failures.isEmpty ? nil : "Updates will retry automatically. " + failures.joined(separator: "\n")
        restore()
    }
    @MainActor private func showCurrent() {
        guard let article = current else { return }
        prepared = ReaderDocument(article)
        if !article.read {
            article.readPosition = (articles.map(\.readPosition).max() ?? 0) + 1
            article.read = true
        }
        save()
        rebuildFeed()
    }
    private struct QueueStamp: Equatable {
        let key: String; let queued: Bool; let read: Bool; let queue: Int; let history: Int
    }
}

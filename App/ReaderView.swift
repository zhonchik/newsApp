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
    private var feed: [Article] {
        var seen = Set<String>()
        let unique = articles.filter { !$0.queued && seen.insert(ArticleIdentity.key(url: $0.url, fallback: $0.key)).inserted }
        return ReadingQueue.ordered(unique, isRead: { $0.read }, readPosition: { $0.readPosition }, queuePosition: { $0.queuePosition })
    }
    private var current: Article? { feed.first { $0.key == selected } }
    private var index: Int { feed.firstIndex { $0.key == selected } ?? 0 }
    private var hiddenText: String { subscriptions.first { $0.id == current?.subscriptionID }?.hiddenText ?? "" }
    private let service = FeedService()
    var body: some View {
        NavigationStack {
            Group {
                if let document = prepared, document.key == selected {
                    ArticleWebView(article: document, hiddenText: hiddenText, move: move)
                        .id(document.key)
                        .accessibilityAction(named: "Next article") { move(1) }
                        .accessibilityAction(named: "Previous article") { move(-1) }
                } else if current != nil {
                    ProgressView("Preparing article…").frame(maxWidth: .infinity, maxHeight: .infinity)
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
            .toolbar {
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
                    Button { showSubscriptions = true } label: { Label("Subscriptions", systemImage: "slider.horizontal.3") }
                }
                if let updateStatus {
                    ToolbarItem { Image(systemName: "exclamationmark.arrow.triangle.2.circlepath").help(updateStatus).accessibilityLabel(updateStatus) }
                }
            }
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
                migrateLibrary(); restore(); initialized = true
                await refresh(force: true)
            }
            .task {
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(300)) } catch { return }
                    if phase == .active { await refresh() }
                }
            }
            .task(id: selected) { showCurrent() }
            .task(id: selected + "|" + feed.map(\.key).joined(separator: "|") + "|" + String(preparationGeneration) + "|" + String(phase == .active)) {
                let candidates = (current.map { [$0] } ?? []) + feed.filter { !$0.read && $0.key != selected } + feed.filter { $0.read && $0.key != selected }
                for article in candidates {
                    guard !Task.isCancelled, phase == .active else { return }
                    await preparation.prepare(article, context: context)
                }
            }
            .onChange(of: showSubscriptions) { _, visible in if !visible { Task { await refresh(force: true) } } }
            .onChange(of: selected) { _, key in
                guard !key.isEmpty else { return }
                if let position = positions.first { position.articleKey = key; position.changed = Date() }
                else { context.insert(ReadingPosition(articleKey: key)) }
                save()
                if key == feed.last?.key { Task { await refresh() } }
            }
            .onChange(of: phase) { _, value in if value == .active && initialized { Task { await refresh() } } }
            .onChange(of: feed.map(\.key)) { _, _ in restore() }
        }.tint(Color(red: 0.14, green: 0.54, blue: 0.51))
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
    private func migrateLibrary() {
        do {
            let all = try context.fetch(FetchDescriptor<Article>()).sorted {
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
                    if selected == article.key { selected = kept.key }
                    context.delete(article)
                } else {
                    known[identity] = article
                    if article.read && article.readPosition == 0 { readPosition += 1; article.readPosition = readPosition }
                    if article.queuePosition == 0 { position += 1; article.queuePosition = position }
                }
            }
            save()
        } catch { errorMessage = error.localizedDescription }
    }
    @MainActor private func refresh(force: Bool = false) async {
        guard !refreshing, !subscriptions.isEmpty, force || Date().timeIntervalSince(lastRefresh) >= 60 else { return }
        refreshing = true; lastRefresh = Date()
        defer { refreshing = false }
        migrateLibrary()
        var failures: [String] = []
        for subscription in subscriptions {
            do {
                let items = try await service.itemsWithRetry(for: subscription)
                guard !Task.isCancelled else { return }
                let active = try context.fetch(FetchDescriptor<Subscription>())
                guard active.contains(where: { $0.id == subscription.id }) else { continue }
                let all = try context.fetch(FetchDescriptor<Article>())
                var known = Dictionary(all.map { (ArticleIdentity.key(url: $0.url, fallback: $0.key), $0) }, uniquingKeysWith: { first, _ in first })
                var position = all.map(\.queuePosition).max() ?? 0
                for item in items.sorted(by: { ($0.published, $0.id) < ($1.published, $1.id) }) {
                    let key = ArticleIdentity.key(url: item.url, fallback: subscription.address + ":" + item.id)
                    if let existing = known[key] {
                        // Re-adding a feed reconnects its saved articles, including read history.
                        if !active.contains(where: { $0.id == existing.subscriptionID }) { existing.subscriptionID = subscription.id }
                        existing.feedHTML = item.html
                        if existing.html.isEmpty { existing.html = item.html }
                    } else {
                        let article = Article(item: item, subscription: subscription)
                        position += 1; article.queuePosition = position
                        context.insert(article); known[key] = article
                    }
                }
                if !subscription.paused {
                    for article in known.values.filter({ $0.subscriptionID == subscription.id && $0.queued }).sorted(by: { $0.queuePosition < $1.queuePosition }) {
                        position += 1; article.queuePosition = position; article.queued = false
                    }
                }
                save()
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
    }
}

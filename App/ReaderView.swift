import SwiftUI
import SwiftData
import SwiftSoup

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(sort: [SortDescriptor(\Article.published), SortDescriptor(\Article.key)]) private var articles: [Article]
    @Query private var subscriptions: [Subscription]
    @Query(sort: \ReadingPosition.changed, order: .reverse) private var positions: [ReadingPosition]
    @State private var selected = ""
    @State private var showSubscriptions = false
    @State private var refreshing = false
    @State private var errorMessage: String?
    private var feed: [Article] { articles.filter { !$0.queued } }
    private var current: Article? { feed.first { $0.key == selected } }
    private var index: Int { feed.firstIndex { $0.key == selected } ?? 0 }
    private let service = FeedService()
    var body: some View {
        NavigationStack {
            Group {
                if let article = current {
                    ArticleWebView(article: article, move: move)
                        .accessibilityAction(named: "Next article") { move(1) }
                        .accessibilityAction(named: "Previous article") { move(-1) }
                } else {
                    ContentUnavailableView {
                        Label("A little more perspective.", systemImage: "text.page")
                    } description: {
                        Text(subscriptions.isEmpty ? "Add an RSS feed or public Telegram channel to start your reading stream." : "Refresh to collect stories. Paused subscriptions keep new stories queued until you resume.")
                    } actions: {
                        Button("Manage subscriptions") { showSubscriptions = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("\(feed.filter { !$0.read }.count) unread")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .accessibilityLabel("\(feed.filter { !$0.read }.count) unread articles")
                }
                ToolbarItem { Button { showSubscriptions = true } label: { Label("Subscriptions", systemImage: "slider.horizontal.3") } }
                ToolbarItem { Button { Task { await refresh() } } label: {
                    if refreshing { ProgressView() } else { Label("Refresh", systemImage: "arrow.clockwise") }
                }.disabled(refreshing) }
            }
            .sheet(isPresented: $showSubscriptions) { SubscriptionsView() }
            .alert("Couldn't update Current", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .task { restore(); await refresh() }
            .task(id: selected) { await extractCurrent() }
            .onChange(of: showSubscriptions) { _, visible in if !visible { Task { await refresh() } } }
            .onChange(of: selected) { _, key in
                guard !key.isEmpty else { return }
                if let position = positions.first { position.articleKey = key; position.changed = Date() }
                else { context.insert(ReadingPosition(articleKey: key)) }
                current?.read = true; save()
            }
            .onChange(of: phase) { _, value in if value == .active { Task { await refresh() } } }
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
        guard feed.indices.contains(next) else { return }
        selected = feed[next].key; feed[next].read = true
        if let position = positions.first { position.articleKey = selected; position.changed = Date() }
        else { context.insert(ReadingPosition(articleKey: selected)) }
        save()
    }
    private func save() { do { try context.save() } catch { errorMessage = error.localizedDescription } }
    @MainActor private func refresh() async {
        guard !refreshing, !subscriptions.isEmpty else { return }
        refreshing = true; defer { refreshing = false }
        var known = Set(articles.map(\.key))
        for subscription in subscriptions {
            do {
                let items = try await service.items(for: subscription)
                for item in items {
                    let key = subscription.id.uuidString + ":" + item.id
                    if known.insert(key).inserted { context.insert(Article(item: item, subscription: subscription)) }
                    else if let existing = articles.first(where: { $0.key == key }), existing.html.isEmpty { existing.html = item.html }
                }
                // Resume releases the backlog; pausing never removes previously visible stories.
                if !subscription.paused { for a in articles where a.subscriptionID == subscription.id { a.queued = false } }
                save()
            } catch { errorMessage = "\(subscription.name): \(error.localizedDescription)" }
        }
        restore()
    }
    @MainActor private func extractCurrent() async {
        guard let article = current, !article.richExtracted, URL(string: article.url)?.host != "t.me" else { return }
        do {
            let html = try await service.articleText(url: article.url)
            guard !Task.isCancelled, !html.isEmpty else { return }
            article.html = html; article.text = (try? SwiftSoup.parse(html).text()) ?? article.text; article.extracted = true; article.richExtracted = true; save()
        } catch { /* Retain feed content offline and retry next time. */ }
    }
}

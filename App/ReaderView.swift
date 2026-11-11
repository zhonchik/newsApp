import SwiftUI
import SwiftData

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.scenePhase) private var phase
    @Query(sort: [SortDescriptor(\Article.published), SortDescriptor(\Article.key)]) private var articles: [Article]
    @Query private var subscriptions: [Subscription]
    @Query(sort: \ReadingPosition.changed, order: .reverse) private var positions: [ReadingPosition]
    @AppStorage("serviceURL") private var serviceURL = ""
    @State private var selected = ""
    @State private var showSubscriptions = false
    @State private var refreshing = false
    @State private var errorMessage: String?
    private var feed: [Article] { articles.filter { !$0.queued } }
    private var current: Article? { feed.first { $0.key == selected } }
    private var index: Int { feed.firstIndex { $0.key == selected } ?? 0 }
    private var service: FeedService? {
        guard let url = URL(string: serviceURL), url.scheme == "https", url.host != nil else { return nil }
        return FeedService(base: url)
    }
    var body: some View {
        NavigationStack {
            Group {
                if let article = current {
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 24) {
                                Color.clear.frame(height: 0).id("top")
                                HStack { Label(article.source, systemImage: "dot.radiowaves.left.and.right"); Spacer(); Text(article.published, style: .date) }
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(article.title).font(.system(.largeTitle, design: .serif, weight: .bold)).accessibilityAddTraits(.isHeader)
                                Rectangle().fill(.tint).frame(width: 40, height: 3)
                                Text(article.text.isEmpty ? "No article text is available. Open the original to read this story." : article.text)
                                    .font(.system(.title3, design: .serif)).lineSpacing(8).textSelection(.enabled)
                                if let url = URL(string: article.url) { Link(destination: url) { Label("Read original", systemImage: "arrow.up.right") }.font(.callout) }
                                Text(article.extracted ? "Reader text · Available offline" : "Feed text · Available offline")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: 680, alignment: .leading).padding(28).frame(maxWidth: .infinity)
                        }
                        .onChange(of: selected) { _, _ in proxy.scrollTo("top", anchor: .top) }
                    }
                    .gesture(DragGesture(minimumDistance: 45).onEnded { value in
                        guard abs(value.translation.width) > abs(value.translation.height) * 1.5 else { return }
                        move(value.translation.width < 0 ? 1 : -1)
                    })
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Button { move(-1) } label: { Label("Previous", systemImage: "chevron.left") }.disabled(index == 0)
                            Spacer()
                            Text("\(index + 1) of \(feed.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            Spacer()
                            Button { move(1) } label: { Label("Next", systemImage: "chevron.right") }.disabled(index + 1 >= feed.count)
                        }.padding().background(.bar)
                    }
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
            .navigationTitle("Current")
            .toolbar {
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
        guard let service else { errorMessage = "Set your HTTPS reading service URL in Subscriptions."; return }
        refreshing = true; defer { refreshing = false }
        var known = Set(articles.map(\.key))
        for subscription in subscriptions {
            do {
                let items = try await service.items(for: subscription)
                for item in items {
                    let key = subscription.id.uuidString + ":" + item.id
                    if known.insert(key).inserted { context.insert(Article(item: item, subscription: subscription)) }
                }
                // Resume releases the backlog; pausing never removes previously visible stories.
                if !subscription.paused { for a in articles where a.subscriptionID == subscription.id { a.queued = false } }
                save()
            } catch { errorMessage = "\(subscription.name): \(error.localizedDescription)" }
        }
        restore()
    }
    @MainActor private func extractCurrent() async {
        guard let article = current, !article.extracted, URL(string: article.url)?.host != "t.me", let service else { return }
        do {
            let text = try await service.articleText(url: article.url)
            guard !Task.isCancelled, !text.isEmpty else { return }
            article.text = text; article.extracted = true; save()
        } catch { /* Retain feed content offline and retry next time. */ }
    }
}

import SwiftUI
import SwiftData
import os

struct ReaderView: View {
    @ObservedObject var library: LibraryContainer
    @Environment(\.scenePhase) private var phase
    @StateObject private var reader = ReaderState()
    @State private var showSettings = false
    init(library: LibraryContainer) {
        self.library = library
        library.beginRestore()
    }
    private var visibleDocument: ReaderDocument? {
        reader.document ?? (reader.starting ? library.launchDocument : nil)
    }
    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await library.restore() }
                .toolbar { toolbar }
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.visible, for: .navigationBar)
                #endif
                .sheet(isPresented: $showSettings, onDismiss: { Task { await reader.settingsClosed() } }) {
                    if let container = library.container { SettingsView().modelContainer(container) }
                }
                .task(id: library.container != nil) {
                    if library.container != nil { await reader.start(library: library) }
                }
                .task(id: reader.selection) { await reader.loadSelected() }
                .task {
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(300)) } catch { return }
                        if phase == .active { await reader.refresh() }
                    }
                }
                .onChange(of: phase) { _, value in if value == .active { Task { await reader.refresh() } } }
        }
        .tint(Color(red: 0.14, green: 0.54, blue: 0.51))
    }
    private func retryStartup() {
        Task {
            if library.container == nil { await library.open() }
            else if reader.startupError != nil { await reader.start(library: library) }
            else if visibleDocument?.key == reader.selection && visibleDocument != nil { reader.retryPage() }
            else { await reader.loadSelected() }
        }
    }
    @ViewBuilder private var content: some View {
        let document = visibleDocument
        if document != nil || (reader.starting && library.error == nil && reader.startupError == nil) {
            HybridArticleReader(launchPage: reader.starting && reader.document == nil ? library.launchPage : nil, article: document, hiddenText: reader.current?.hiddenText ?? document?.hiddenText ?? "", renderVersion: reader.renderVersion, onDisplay: { renderer in
                guard let document else { return }
                if !reader.pageVisible {
                    LaunchMetrics.mark("First \(renderer) article layout confirmed", finished: true)
                    os_signpost(.event, log: LaunchMetrics.log, name: "First readable article")
                }
                reader.pageDidDisplay(document.key)
                Task { await library.open() }
                Task(priority: .utility) { try? await MediaCache.shared.saveFormattedBody() }
            }, onFailure: { message in
                reader.pageFailed(message)
                Task { await library.open() }
            }, reload: { await reader.reloadArticle() }, move: reader.move)
                .accessibilityAction(named: "Next article") { reader.move(1) }
                .accessibilityAction(named: "Previous article") { reader.move(-1) }
                .overlay {
                    if let error = reader.articleError ?? library.error ?? (reader.articles.isEmpty ? reader.startupError : nil) {
                        VStack {
                            Text(error)
                            Button("Try again") { retryStartup() }
                        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    }
                }
        } else if let error = reader.articleError ?? reader.startupError ?? library.error {
            ContentUnavailableView {
                Label("Couldn't load the article", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
            } description: { Text(error) } actions: {
                Button("Try again") { Task {
                    if reader.current == nil {
                        if library.container != nil { await reader.start(library: library) }
                        else { await library.open() }
                    }
                    else { await reader.loadSelected() }
                } }
            }
        } else if reader.starting || reader.current != nil {
            Color.clear.accessibilityHidden(true)
        } else {
            ContentUnavailableView {
                Label("A little more perspective.", systemImage: "text.page")
            } description: {
                Text(reader.subscriptions.isEmpty ? "Add an RSS feed or public Telegram channel to start your reading queue." : "Stories update automatically. Paused subscriptions keep new stories queued until you resume.")
            } actions: { Button("Manage subscriptions") { showSettings = true }.buttonStyle(.borderedProminent) }
        }
    }
    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            UnreadCountLabel(count: reader.unreadCount, updating: reader.isUpdating, failed: reader.updateFailed, message: reader.updateMessage)
        }
        ToolbarItem {
            Button {
                if let key = reader.firstUnread { reader.selection = key }
            } label: { Label("Go to first unread", systemImage: "forward.end.fill") }
            .disabled(reader.unreadCount == 0)
        }
        ToolbarItem {
            Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                .disabled(library.container == nil)
        }
    }
}


private struct UnreadCountLabel: View {
    let count: Int
    let updating: Bool
    let failed: Bool
    let message: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dimCount = false

    var body: some View {
        Text("\(count) unread")
            .font(.caption.monospacedDigit())
            .foregroundStyle(failed ? Color(red: 0.78, green: 0.40, blue: 0.40) : Color.secondary)
            .opacity(dimCount ? 0.35 : 1)
            .accessibilityValue(updating ? "Updating" : message)
            .help(message)
            .task(id: [updating, reduceMotion]) {
                guard updating, !reduceMotion else { dimCount = false; return }
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.8)) { dimCount.toggle() }
                    do { try await Task.sleep(for: .milliseconds(800)) } catch { break }
                }
                dimCount = false
            }
    }
}

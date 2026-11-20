import SwiftUI
import SwiftData
import os

struct ReaderView: View {
    @ObservedObject var library: LibraryContainer
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var reader = ReaderState()
    @State private var showSettings = false
    @State private var dimCount = false
    private var visibleDocument: ReaderDocument? {
        reader.document ?? (reader.starting ? library.launchDocument : nil)
    }
    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task { await library.open() }
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
        if let document = visibleDocument {
            ArticleWebView(article: document, hiddenText: reader.current?.hiddenText ?? document.hiddenText, renderVersion: reader.renderVersion, onDisplay: {
                if !reader.pageVisible {
                    os_signpost(.event, log: LaunchMetrics.log, name: "First WebKit display")
                    os_signpost(.event, log: LaunchMetrics.log, name: "First readable article")
                }
                reader.pageDidDisplay(document.key)
            }, onFailure: reader.pageFailed, reload: { await reader.reloadArticle() }, move: reader.move)
                .accessibilityAction(named: "Next article") { reader.move(1) }
                .accessibilityAction(named: "Previous article") { reader.move(-1) }
                .overlay {
                    if let error = reader.articleError ?? library.error ?? (reader.articles.isEmpty ? reader.startupError : nil) {
                        VStack {
                            Text(error)
                            Button("Try again") { retryStartup() }
                        }.padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else if !reader.selection.isEmpty && document.key != reader.selection {
                        ProgressView("Loading article…")
                            .padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
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
            ProgressView().accessibilityLabel(reader.current?.title ?? "Opening library")
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
            Text("\(reader.unreadCount) unread")
                .font(.caption.monospacedDigit())
                .foregroundStyle(reader.updateFailed ? Color(red: 0.78, green: 0.40, blue: 0.40) : Color.secondary)
                .opacity(dimCount ? 0.35 : 1)
                .accessibilityValue(reader.isUpdating ? "Updating" : reader.updateMessage)
                .help(reader.updateMessage)
                .task(id: [reader.isUpdating, reduceMotion]) {
                    guard reader.isUpdating, !reduceMotion else { dimCount = false; return }
                    while !Task.isCancelled {
                        withAnimation(.easeInOut(duration: 0.8)) { dimCount.toggle() }
                        do { try await Task.sleep(for: .milliseconds(800)) } catch { break }
                    }
                    dimCount = false
                }
        }
        ToolbarItem {
            Button {
                if let unread = reader.articles.first(where: { !$0.read }) { reader.selection = unread.key }
            } label: { Label("Go to first unread", systemImage: "forward.end.fill") }
            .disabled(reader.unreadCount == 0)
        }
        ToolbarItem {
            Button { showSettings = true } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                .disabled(library.container == nil)
        }
    }
}

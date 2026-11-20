import SwiftUI
import SwiftData
import os

struct ReaderView: View {
    @ObservedObject var library: LibraryContainer
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("lightText") private var lightText = "#202020"
    @AppStorage("lightBackground") private var lightBackground = "#FFFFFF"
    @AppStorage("darkText") private var darkText = "#DEDCD8"
    @AppStorage("darkBackground") private var darkBackground = "#181818"
    @Environment(\.scenePhase) private var phase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var reader = ReaderState()
    @State private var showSettings = false
    @State private var dimCount = false
    @State private var preparedPreview: LaunchPreview?
    @State private var recordedReadable = false
    private var visibleDocument: ReaderDocument? {
        reader.document ?? (reader.starting ? library.launchDocument : nil)
    }
    private struct PreviewInput: Equatable {
        let document: ReaderDocument
        let hiddenText: String
    }
    private var previewInput: PreviewInput? {
        visibleDocument.map { PreviewInput(document: $0, hiddenText: reader.current?.hiddenText ?? $0.hiddenText) }
    }
    private var launchPreview: LaunchPreview? {
        guard let candidate = preparedPreview ?? library.preview else { return nil }
        let key = reader.selection.isEmpty ? visibleDocument?.key : reader.selection
        return candidate.key == key || (key == nil && reader.starting) ? candidate : nil
    }
    private func recordReadable() {
        guard !recordedReadable else { return }
        recordedReadable = true
        os_signpost(.event, log: LaunchMetrics.log, name: "First readable article")
    }
    var body: some View {
        NavigationStack {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay { preparationOverlay }
                .background {
                    FirstFrameGate { Task { await library.open() } }
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
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
                .task(id: previewInput) {
                    guard let input = previewInput else {
                        if !reader.starting && reader.startupError == nil && reader.selection.isEmpty {
                            LaunchPreview.clear()
                            preparedPreview = nil
                            library.preview = nil
                        }
                        return
                    }
                    let preview = await Task.detached(priority: .userInitiated) {
                        try? LaunchPreview.make(from: input.document, hiddenText: input.hiddenText)
                    }.value
                    guard !Task.isCancelled, let preview else { return }
                    preparedPreview = preview
                    preview.save()
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
    @ViewBuilder private var preparationOverlay: some View {
        if !reader.pageVisible, let preview = launchPreview,
           !preview.text.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(preview.source).font(.caption)
                    if !preview.title.isEmpty { Text(preview.title).font(.title.bold()) }
                    Text(preview.text).font(.system(.body, design: .serif)).textSelection(.enabled)
                    if let error = reader.articleError ?? reader.startupError ?? library.error {
                        Text(error).font(.callout)
                        Button("Try again") { retryStartup() }
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                .padding()
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .foregroundStyle(themeColor(colorScheme == .dark ? darkText : lightText))
            .background(themeColor(colorScheme == .dark ? darkBackground : lightBackground))
            .onAppear { recordReadable() }
        } else if !reader.pageVisible && (reader.starting || reader.loadingArticle || reader.current != nil || reader.document != nil || library.launchDocument != nil) {
            VStack(spacing: 12) {
                if let error = reader.articleError ?? reader.startupError ?? library.error {
                    Text("Couldn't prepare the reader").font(.headline)
                    Text(error).font(.callout)
                    Button("Try again") { retryStartup() }
                } else {
                    ProgressView()
                    Text("Preparing…").font(.headline)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .foregroundStyle(themeColor(colorScheme == .dark ? darkText : lightText))
            .tint(themeColor(colorScheme == .dark ? darkText : lightText))
            .background(themeColor(colorScheme == .dark ? darkBackground : lightBackground))
            .accessibilityElement(children: .contain)
        }
    }
    private func retryStartup() {
        Task {
            if library.container == nil { await library.open() }
            else if reader.startupError != nil { await reader.start(library: library) }
            else if visibleDocument?.key == reader.selection && visibleDocument != nil { reader.retryPage() }
            else { await reader.loadSelected() }
        }
    }
    private func themeColor(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    @ViewBuilder private var content: some View {
        if let document = visibleDocument {
            ArticleWebView(article: document, hiddenText: reader.current?.hiddenText ?? document.hiddenText, renderVersion: reader.renderVersion, onDisplay: {
                if !reader.pageVisible { os_signpost(.event, log: LaunchMetrics.log, name: "First WebKit display") }
                recordReadable()
                reader.pageDidDisplay()
            }, onFailure: reader.pageFailed, reload: { await reader.reloadArticle() }, move: reader.move)
                .accessibilityAction(named: "Next article") { reader.move(1) }
                .accessibilityAction(named: "Previous article") { reader.move(-1) }
                .overlay {
                    if !reader.selection.isEmpty && document.key != reader.selection {
                        VStack(spacing: 12) {
                            if let error = reader.articleError {
                                Text(error)
                                Button("Try again") { Task { await reader.loadSelected() } }
                            } else { ProgressView("Loading article…") }
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
            ProgressView(reader.current?.title ?? "Opening library…").padding()
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

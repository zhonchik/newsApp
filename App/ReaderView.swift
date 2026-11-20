import SwiftUI
import SwiftData

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
                    if let container = library.container { await reader.start(container: container) }
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
        if !reader.pageVisible && (reader.starting || reader.loadingArticle || reader.current != nil || reader.document != nil || library.launchDocument != nil) {
            VStack(spacing: 12) {
                if let error = reader.articleError ?? reader.startupError ?? library.error {
                    Text("Couldn't prepare the reader").font(.headline)
                    Text(error).font(.callout)
                    Button("Try again") {
                        if reader.document != nil || library.launchDocument != nil { reader.retryPage() }
                        else if reader.current != nil { Task { await reader.loadSelected() } }
                        else { Task {
                            if let container = library.container { await reader.start(container: container) }
                            else { await library.open() }
                        } }
                    }
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
    private func themeColor(_ hex: String) -> Color {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
    @ViewBuilder private var content: some View {
        if let document = reader.document ?? (reader.starting ? library.launchDocument : nil) {
            ArticleWebView(article: document, hiddenText: reader.current?.hiddenText ?? document.hiddenText, renderVersion: reader.renderVersion, onDisplay: reader.pageDidDisplay, onFailure: reader.pageFailed, reload: { await reader.reloadArticle() }, move: reader.move)
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
                        if let container = library.container { await reader.start(container: container) }
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

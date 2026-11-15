import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        TabView {
            SubscriptionsView()
                .tabItem { Label("Subscriptions", systemImage: "dot.radiowaves.left.and.right") }
            NavigationStack {
                Form { ThemeSettings() }.formStyle(.grouped)
                    .navigationTitle("Colors")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }.tabItem { Label("Colors", systemImage: "paintpalette") }
            NavigationStack {
                CacheSettings().navigationTitle("Cache")
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            }.tabItem { Label("Cache", systemImage: "internaldrive") }
        }.frame(minWidth: 340, minHeight: 500)
    }
}

struct CacheSettings: View {
    @AppStorage("readerCacheLimitMB") private var limitMB = 512
    @State private var bytes: Int?
    @State private var errorMessage: String?
    var body: some View {
        Form {
            Section("Storage") {
                LabeledContent("Cached data") {
                    if let bytes { Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)) }
                    else { ProgressView() }
                }
                Stepper(value: $limitMB, in: 64...8192, step: 64) {
                    LabeledContent("Cache limit", value: "\(limitMB) MiB")
                }
                Text("Older cached text, images, and videos are removed to stay within this limit. Article links and reading history are kept so you can download them again.").font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Text("Opening an article uses cached text and images first. Missing data downloads automatically. Pull down at the top of an article to reload it. Videos cache when playback starts.")
                Text("This size covers the article and media cache. The library and YouTube’s managed player storage are separate.").font(.caption).foregroundStyle(.secondary)
            }
            if let errorMessage { Section { Text(errorMessage).foregroundStyle(.secondary) } }
        }
        .formStyle(.grouped)
        .task {
            while !Task.isCancelled {
                await measure()
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        .onChange(of: limitMB) { _, _ in Task { await measure() } }
    }
    private func measure() async {
        do { bytes = try await MediaCache.shared.usage(); errorMessage = nil }
        catch { errorMessage = error.localizedDescription }
    }
}

import SwiftUI
import SwiftData

@MainActor final class LibraryContainer: ObservableObject {
    @Published var container: ModelContainer?
    @Published var launchDocument: ReaderDocument?
    @Published var error: String?
    private var opening = false
    func open() async {
        guard container == nil, !opening else { return }
        opening = true; error = nil
        defer { opening = false }
        do {
            // This read needs no SwiftData container or migration.
            launchDocument = await MediaCache.shared.launchDocument()
            container = try await Task.detached(priority: .userInitiated) {
                let schema = Schema([Subscription.self, Article.self, ReadingPosition.self])
                #if LOCAL_ONLY
                let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
                #else
                let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
                #endif
                return try ModelContainer(for: schema, configurations: [config])
            }.value
        } catch { self.error = error.localizedDescription }
    }
}

@main struct CurrentApp: App {
    @StateObject private var library = LibraryContainer()
    var body: some Scene {
        WindowGroup {
            // Keep the same reader/WebKit view when the database becomes available.
            ReaderView(library: library)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 800)
        #endif
    }
}

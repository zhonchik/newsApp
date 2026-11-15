import SwiftUI
import SwiftData

@MainActor final class LibraryContainer: ObservableObject {
    @Published var container: ModelContainer?
    @Published var error: String?
    private var opening = false
    func open() async {
        guard container == nil, !opening else { return }
        opening = true; error = nil
        defer { opening = false }
        do {
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
            Group {
                if let container = library.container { ReaderView().modelContainer(container) }
                else if let error = library.error {
                    VStack(spacing: 12) {
                        Text("Couldn't open the library").font(.headline)
                        Text(error)
                        Button("Try again") { Task { await library.open() } }
                    }.padding()
                } else { ProgressView("Opening library…").padding() }
            }.task { await library.open() }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 800)
        #endif
    }
}

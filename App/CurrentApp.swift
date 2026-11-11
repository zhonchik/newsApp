import SwiftUI
import SwiftData

@main struct CurrentApp: App {
    private let container: ModelContainer
    init() {
        do {
            let schema = Schema([Subscription.self, Article.self, ReadingPosition.self])
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            container = try ModelContainer(for: schema, configurations: [config])
        } catch {
            fatalError("Unable to open the article library: \(error)")
        }
    }
    var body: some Scene {
        WindowGroup { ReaderView() }
            .modelContainer(container)
        #if os(macOS)
            .defaultSize(width: 1000, height: 800)
        #endif
    }
}

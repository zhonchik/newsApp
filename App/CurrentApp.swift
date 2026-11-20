import SwiftUI
import SwiftData
import os

enum LaunchMetrics {
    static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Current", category: .pointsOfInterest)
}

@MainActor final class LibraryContainer: ObservableObject {
    static let shared = LibraryContainer()
    @Published var container: ModelContainer?
    @Published var launchDocument: ReaderDocument?
    @Published var error: String?
    private var opening = false
    private var store: Task<LibraryWorker, Error>?

    func worker() async throws -> LibraryWorker {
        if let store { return try await store.value }
        let task = Task.detached(priority: .userInitiated) {
            let id = OSSignpostID(log: LaunchMetrics.log)
            os_signpost(.begin, log: LaunchMetrics.log, name: "Open store", signpostID: id)
            defer { os_signpost(.end, log: LaunchMetrics.log, name: "Open store", signpostID: id) }
            let schema = Schema([Subscription.self, Article.self, ReadingPosition.self])
            #if LOCAL_ONLY
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            #else
            let config = ModelConfiguration(schema: schema, cloudKitDatabase: .automatic)
            #endif
            let container = try ModelContainer(for: schema, configurations: [config])
            return LibraryWorker(modelContainer: container)
        }
        store = task
        do { return try await task.value }
        catch { store = nil; throw error }
    }

    func open() async {
        guard container == nil, !opening else { return }
        opening = true; error = nil
        defer { opening = false }
        async let openingWorker = worker()
        let id = OSSignpostID(log: LaunchMetrics.log)
        os_signpost(.begin, log: LaunchMetrics.log, name: "Read launch cache", signpostID: id)
        launchDocument = await MediaCache.shared.launchDocument()
        os_signpost(.end, log: LaunchMetrics.log, name: "Read launch cache", signpostID: id)
        do {
            let library = try await openingWorker
            container = library.modelContainer
        } catch { self.error = error.localizedDescription }
    }
}

@main struct CurrentApp: App {
    @StateObject private var library = LibraryContainer.shared
    #if os(iOS)
    @UIApplicationDelegateAdaptor(ReaderAppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var phase
    #endif
    var body: some Scene {
        WindowGroup {
            ReaderView(library: library)
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 800)
        #else
        .onChange(of: phase) { _, phase in
            if phase == .background { ReaderAppDelegate.schedule() }
        }
        #endif
    }
}

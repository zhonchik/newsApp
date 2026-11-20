#if os(iOS)
import BackgroundTasks
import UIKit
import os

@MainActor final class ReaderAppDelegate: NSObject, UIApplicationDelegate {
    private static let prefix = Bundle.main.bundleIdentifier!
    private static let refreshID = prefix + ".refresh"
    private static let maintenanceID = prefix + ".maintenance"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        for identifier in [Self.refreshID, Self.maintenanceID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated { Self.run(task) }
            }
        }
        return true
    }

    static func schedule() {
        submit(refreshID)
        submit(maintenanceID)
    }

    private static func submit(_ identifier: String) {
        let request: BGTaskRequest
        if identifier == refreshID {
            request = BGAppRefreshTaskRequest(identifier: identifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        } else {
            request = BGProcessingTaskRequest(identifier: identifier)
            request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3600)
        }
        do { try BGTaskScheduler.shared.submit(request) }
        catch { Logger().debug("Background scheduling unavailable: \(error.localizedDescription)") }
    }

    private static func run(_ task: BGTask) {
        submit(task.identifier)
        let work = Task {
            do {
                let worker = try await LibraryContainer.shared.worker()
                try Task.checkCancellation()
                var succeeded = true
                if task.identifier == maintenanceID {
                    try await worker.migrateContent()
                } else {
                    let service = FeedService()
                    for feed in try await worker.feedSubscriptions() {
                        try Task.checkCancellation()
                        do {
                            let items = try await service.itemsWithRetry(address: feed.address, kind: feed.kind)
                            try Task.checkCancellation()
                            _ = try await worker.importItems(items, subscriptionID: feed.id)
                        } catch {
                            try Task.checkCancellation()
                            succeeded = false
                        }
                    }
                }
                task.setTaskCompleted(success: succeeded && !Task.isCancelled)
            } catch { task.setTaskCompleted(success: false) }
        }
        task.expirationHandler = { work.cancel() }
    }
}
#endif

import Foundation

public enum NetworkRetry {
    public static func perform<T>(delay: Duration = .seconds(2), operation: () async throws -> T) async throws -> T {
        do { return try await operation() }
        catch {
            guard !Task.isCancelled, let network = error as? URLError,
                  [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost].contains(network.code) else { throw error }
            try await Task.sleep(for: delay)
            return try await operation()
        }
    }
}

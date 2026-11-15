import Foundation

/// Only feed fetch/import errors affect subscription-update status.
/// Optional extraction/image caching has its own background lifecycle.
public struct RefreshOutcome: Sendable {
    public var newArticles = 0
    public var errors: [String] = []
    public init() {}
    public var failed: Bool { !errors.isEmpty }
    public var message: String {
        if failed { return errors.joined(separator: "\n") }
        return newArticles == 0 ? "Up to date · no new articles" : "Subscriptions updated"
    }
}

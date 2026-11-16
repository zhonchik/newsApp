import Foundation
import SwiftSoup

/// Network, parsing, and cache writes are isolated from the main actor.
actor ArticlePreparation {
    private var running: [String: (id: UUID, task: Task<CachedArticle, Error>)] = [:]
    private let service = FeedService()
    func prepare(_ link: ArticleLink, force: Bool = false) async throws -> CachedArticle {
        if let running = running[link.key] {
            let task = running.task
            if !force { return try await task.value }
            _ = try? await task.value
        }
        if !force, let cached = await MediaCache.shared.article(link.key), cached.revision >= ContentRules.revision { return cached }
        let task = Task { try await self.fetch(link, force: force) }
        let id = UUID()
        running[link.key] = (id, task)
        defer { if running[link.key]?.id == id { running[link.key] = nil } }
        return try await task.value
    }
    private func fetch(_ link: ArticleLink, force: Bool) async throws -> CachedArticle {
        let cached = await MediaCache.shared.article(link.key)
        do {
            let html = try await service.articleText(url: link.url)
            guard !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw URLError(.cannotParseResponse) }
            let content = CachedArticle(text: try SwiftSoup.parse(html).text(), html: html, feedHTML: cached?.feedHTML ?? "", revision: ContentRules.revision)
            try await MediaCache.shared.storeArticle(content, key: link.key)
            return content
        } catch {
            if !force, let cached { return cached }
            throw error
        }
    }
}

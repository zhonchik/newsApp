import Foundation
import SwiftData
import SwiftSoup

/// One shared task per article. Selection never waits for this network work.
@MainActor final class ArticlePreparation {
    private var running: [String: Task<String?, Never>] = [:]
    private var attempted: [String: Date] = [:]
    func prepare(_ article: Article, context: ModelContext) async {
        guard !ContentRules.isTelegram(article.url), article.contentRevision < ContentRules.revision else { return }
        let key = article.key
        if running[key] == nil {
            guard Date().timeIntervalSince(attempted[key] ?? .distantPast) > 300 else { return }
            attempted[key] = Date()
            let url = article.url
            running[key] = Task { try? await FeedService().articleText(url: url) }
        }
        guard let task = running[key] else { return }
        let html = await task.value
        running[key] = nil
        guard article.modelContext != nil, let html, !html.isEmpty else { return }
        let text = await Task.detached(priority: .utility) { (try? SwiftSoup.parse(html).text()) ?? "" }.value
        guard article.modelContext != nil else { return }
        article.html = html
        article.text = text
        article.extracted = true; article.richExtracted = true
        article.contentRevision = ContentRules.revision
        try? context.save()
    }
}

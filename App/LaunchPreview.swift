#if SWIFT_PACKAGE
import ReaderContent
#endif
import Foundation
import SwiftSoup
import os

enum LaunchMetrics {
    static let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Current", category: .pointsOfInterest)
}

struct LaunchPreview: Codable, Equatable, Sendable {
    let key: String
    let title: String
    let source: String
    let text: String

    private static let storageKey = "readerLaunchPreview.v1"

    static func saved() -> Self? {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func clear() { UserDefaults.standard.removeObject(forKey: storageKey) }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.storageKey) }
    }

    static func make(from article: ReaderDocument, hiddenText: String) throws -> Self {
        let doc: Document
        if article.text.isEmpty {
            doc = try SwiftSoup.parse(article.html.isEmpty ? article.feedHTML : article.html)
        } else {
            doc = try SwiftSoup.parse("")
            try doc.body()?.text(article.text)
        }
        try ContentRules.clean(doc, url: article.url, hiddenText: hiddenText)
        // Telegram titles duplicate the beginning of the unfiltered message.
        return Self(key: article.key, title: ContentRules.isTelegram(article.url) ? "" : String(article.title.prefix(250)),
                    source: String(article.source.prefix(100)), text: String(try doc.text().prefix(2400)))
    }
}

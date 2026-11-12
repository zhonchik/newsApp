import Foundation
import SwiftSoup

public enum ContentRules {
    public static let revision = 3
    public static let telegramNotice = "НАСТОЯЩИЙ МАТЕРИАЛ ПРОИЗВЕДЕН ИНОСТРАННЫМ АГЕНТОМ ГАЛЛЯМОВЫМ АББАСОМ РАДИКОВИЧЕМ. 18+"
    public static func defaultHiddenText(address: String) -> String {
        address.lowercased().replacingOccurrences(of: "@", with: "") == "abbasgallyamovpolitics" ? telegramNotice : ""
    }
    public static func isTelegram(_ url: String) -> Bool { URL(string: url)?.host?.lowercased() == "t.me" }
    public static func articleBody(page: String, url: String) throws -> String? {
        let document = try SwiftSoup.parse(page, url)
        let host = URL(string: url)?.host?.lowercased() ?? ""
        try removeAds(document, host: host)
        let selector: String
        switch host {
        case "nplus1.ru", "www.nplus1.ru": selector = "[data-heading-wrap]"
        case "f1news.ru", "www.f1news.ru": selector = "article.post .post_content"
        case "macrumors.com", "www.macrumors.com": selector = "article .js-content"
        default: return nil
        }
        guard let selected = try document.select(selector).first(), !(try selected.text()).isEmpty else { return nil }
        let body: Element
        if host == "nplus1.ru" || host == "www.nplus1.ru" {
            // One story contains multiple material blocks. The read-next section
            // sits outside data-heading-wrap; retain every block of the current story.
            let blocks = try selected.select(".n1_material, figure")
            guard !blocks.isEmpty() else { return nil }
            let joined = try blocks.map { try $0.outerHtml() }.joined(separator: "\n")
            guard let content = try SwiftSoup.parse(joined, url).body() else { return nil }
            body = content
        } else { body = selected }
        try body.select("script, style, nav, aside, .banner, .inpage_container, .post_error, .post_error_mobile, .post_more").remove()
        // Normalize lazy and relative image sources before dropping the page's base URL.
        for image in try body.select("img") {
            let lazy = try image.attr("data-src")
            if !lazy.isEmpty { try image.attr("src", lazy) }
            let absolute = try image.absUrl("src")
            if !absolute.isEmpty { try image.attr("src", absolute) }
        }
        return try body.html()
    }
    public static func clean(_ document: Document, url: String, hiddenText: String) throws {
        let host = URL(string: url)?.host?.lowercased() ?? ""
        try removeAds(document, host: host)
        if host == "www.macrumors.com" || host == "macrumors.com" {
            // Fallback for already-cached extraction and feed content.
            for heading in try document.select("h1,h2,h3,h4") where try heading.text().trimmingCharacters(in: .whitespacesAndNewlines) == "Popular Stories" {
                var next = try heading.nextElementSibling()
                while let node = next { next = try node.nextElementSibling(); try node.remove() }
                try heading.remove()
            }
        }
        if host == "www.f1news.ru" || host == "f1news.ru" {
            try document.select(".post_error, .post_error_mobile, .post_more").remove()
            for phrase in ["Нашли опечатку? Выделите её и нажмите Ctrl+Enter!", "Нашли опечатку? Выделите её и нажмите кнопку поиска.", "Предыдущая новость", "Следующая новость"] {
                try removeText(phrase, from: document)
            }
        }
        for phrase in hiddenText.components(separatedBy: .newlines) where !phrase.trimmingCharacters(in: .whitespaces).isEmpty {
            try removeText(phrase, from: document)
        }
    }
    private static func removeAds(_ document: Document, host: String) throws {
        guard host == "nplus1.ru" || host == "www.nplus1.ru" else { return }
        try document.select(".ad, .ads, .advertisement, .banner, [data-ad], [data-ad-client], [data-erid], [id^=adfox], [class*=header-bidding], [class*=adv-banner], [id*=adv-banner], iframe").remove()
    }
    // Remove only matching text across inline tags, retaining all surrounding markup.
    private static func removeText(_ phrase: String, from document: Document) throws {
        var nodes: [TextNode] = []
        func visit(_ node: Node) {
            if let text = node as? TextNode { nodes.append(text) }
            for child in node.getChildNodes() { visit(child) }
        }
        visit(document)
        let strings = nodes.map { $0.getWholeText() }
        let joined = strings.joined()
        let pattern = phrase.split(whereSeparator: { $0.isWhitespace }).map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "\\s*")
        guard !pattern.isEmpty else { return }
        let matches = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive]).matches(in: joined, range: NSRange(location: 0, length: (joined as NSString).length))
        var offset = 0
        for (index, node) in nodes.enumerated() {
            let text = NSMutableString(string: strings[index])
            let originalLength = text.length
            let range = NSRange(location: offset, length: originalLength)
            for match in matches.reversed() {
                let intersection = NSIntersectionRange(range, match.range)
                if intersection.length > 0 { text.deleteCharacters(in: NSRange(location: intersection.location - offset, length: intersection.length)) }
            }
            try node.text(text as String)
            offset += originalLength
        }
    }
}

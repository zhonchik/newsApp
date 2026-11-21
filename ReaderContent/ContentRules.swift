import Foundation
import SwiftSoup

public enum ContentRules {
    public static let revision = 7

    static let adSelector = ".ad, .ads, .advertisement, .ad-banner, .adv-banner, [id^=ad-banner-], [id^=adv-banner-], [data-ad], [data-ad-client], [data-ad-slot], [data-erid]"
    static let bannerLinkPattern = #"^[^?#]*\?(?:[^&#]*&)*utm_medium=[^&#]*banner[^&#]*(?:[&#]|$)"#

    public static func isTelegram(_ url: String) -> Bool { URL(string: url)?.host?.lowercased() == "t.me" }

    public static func clean(_ document: Document, hiddenText: String) throws {
        try removeAds(from: document)
        for phrase in hiddenText.components(separatedBy: .newlines) where !phrase.trimmingCharacters(in: .whitespaces).isEmpty {
            try removeText(phrase, from: document)
        }
    }

    public static func removeAds(from document: Document) throws {
        try document.select(adSelector).remove()
        for link in try document.select("a[href]:has(img)") {
            if try link.text().isEmpty,
               try link.attr("href").range(of: bannerLinkPattern, options: [.regularExpression, .caseInsensitive]) != nil {
                try link.remove()
            }
        }
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

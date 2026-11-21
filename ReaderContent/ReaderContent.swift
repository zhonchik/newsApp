import Foundation
import SwiftSoup

public enum ReaderContent {
    /// Preserve publisher feed photos when full-text extraction omits them.
    /// Resolve relative URLs before sanitizing so WebKit and the cleaner agree.
    public static func html(body: String, feed: String, baseURL: String, hiddenText: String = "") throws -> String {
        let document = try SwiftSoup.parse(body, baseURL)
        try ContentRules.clean(document, hiddenText: hiddenText)
        let fallback = try SwiftSoup.parse(feed, baseURL)
        try ContentRules.clean(fallback, hiddenText: hiddenText)
        let previews = try VideoPreview.youtube(in: (document.body()?.html() ?? "") + (fallback.body()?.html() ?? ""), baseURL: baseURL)
        let feedImages = try fallback.select("img[src]").compactMap { image -> (Element, String)? in
            guard let source = MediaURL.resolve(try image.attr("src"), baseURL: baseURL) else { return nil }
            return (image, source)
        }
        let feedSources = feedImages.map { $0.1 }
        var seen = Set<String>()
        for image in try document.select("img[src]") {
            guard let source = MediaURL.resolve(try image.attr("src"), baseURL: baseURL) else {
                try image.remove()
                continue
            }
            let original = MediaURL.originalImage(for: source, in: feedSources)
            let displaySource = original ?? source
            guard seen.insert(ArticleIdentity.imageKey(displaySource)).inserted else {
                try image.remove()
                continue
            }
            try image.attr("src", displaySource)
            if original != nil { try image.attr("data-reader-original", "") }
        }
        var photos = ""
        for (image, source) in feedImages where seen.insert(ArticleIdentity.imageKey(source)).inserted {
            try image.attr("src", source)
            photos += try image.outerHtml()
        }
        if !photos.isEmpty, let body = document.body() {
            let firstBlock = try body.select("p, figure, img, video").first { block in
                !block.parents().contains { $0.tagName() == "header" }
            }
            if let firstBlock, firstBlock.tagName() == "figure", try firstBlock.select("figcaption").first() != nil {
                // Keep the article's captioned lead photo first. Feed-only media is supplementary.
                try body.append(photos)
            } else if let header = body.children().first(), header.tagName() == "header" {
                try header.after(photos)
            } else {
                try body.prepend(photos)
            }
        }
        // Publisher iframes/scripts are removed. Only our validated YouTube embeds
        // are appended after cleaning, and only HTTPS video sources survive.
        let whitelist = try Whitelist.relaxed()
        try whitelist.addTags("video", "source", "figure", "figcaption")
        try whitelist.addAttributes("img", "data-reader-original")
        try whitelist.addAttributes("video", "src", "poster", "controls", "playsinline", "preload", "width", "height")
        try whitelist.addAttributes("source", "src", "type")
        try whitelist.addProtocols("video", "src", "https")
        try whitelist.addProtocols("video", "poster", "https")
        try whitelist.addProtocols("source", "src", "https")
        try whitelist.addTags("dfn")
        try whitelist.addAttributes("dfn", "title")
        let clean = try SwiftSoup.clean(document.body()?.html() ?? body, baseURL, whitelist) ?? ""
        let safe = try SwiftSoup.parse(clean)
        for video in try safe.select("video") {
            try video.attr("controls", "").attr("playsinline", "").attr("preload", "metadata")
        }
        try renderDefinitions(in: safe)
        return (try safe.body()?.html() ?? "") + previews
    }

    private static func renderDefinitions(in document: Document) throws {
        for (index, note) in try document.select("dfn[title]").enumerated() {
            let definition = try note.attr("title").trimmingCharacters(in: .whitespacesAndNewlines)
            let term = try note.text()
            guard !term.isEmpty, !definition.isEmpty else { continue }
            let id = "reader-definition-\(index)"
            let trigger = Element(try Tag.valueOf("button"), "")
            try trigger.attr("type", "button").attr("popovertarget", id).text(term)
            let popup = Element(try Tag.valueOf("span"), "")
            try popup.attr("id", id).attr("popover", "auto").attr("role", "note").attr("aria-label", term).text(definition)
            try note.before(trigger)
            try note.replaceWith(popup)
        }
    }
}

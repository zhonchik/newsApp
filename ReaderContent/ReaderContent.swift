import Foundation
import SwiftSoup

public enum ReaderContent {
    /// Preserve publisher feed photos when full-text extraction omits them.
    /// Resolve relative URLs before sanitizing so WebKit and the cleaner agree.
    public static func html(body: String, feed: String, baseURL: String, hiddenText: String = "") throws -> String {
        let previews = try VideoPreview.youtube(in: body + feed, baseURL: baseURL)
        let document = try SwiftSoup.parse(ContentRules.normalizeNotes(body, url: baseURL), baseURL)
        try ContentRules.clean(document, url: baseURL, hiddenText: hiddenText)
        let fallback = try SwiftSoup.parse(ContentRules.normalizeNotes(feed, url: baseURL), baseURL)
        try ContentRules.clean(fallback, url: baseURL, hiddenText: hiddenText)
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
        try document.body()?.prepend(photos)
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
        let isNPlusOne = ContentRules.isNPlusOne(baseURL)
        if isNPlusOne {
            try whitelist.addTags("app-note")
            try whitelist.addAttributes("app-note", "data-definition", "text")
        }
        let clean = try SwiftSoup.clean(document.body()?.html() ?? body, baseURL, whitelist) ?? ""
        let safe = try SwiftSoup.parse(clean)
        for video in try safe.select("video") {
            try video.attr("controls", "").attr("playsinline", "").attr("preload", "metadata")
        }
        if isNPlusOne {
            try renderNPlusOneNotes(in: safe)
        }
        return (try safe.body()?.html() ?? "") + previews
    }

    private static func renderNPlusOneNotes(in document: Document) throws {
        for (index, note) in try document.select("app-note").enumerated() {
            let definition = try note.attr("data-definition")
            let term = try note.hasAttr("data-definition") ? note.text() : note.attr("text")
            guard !term.isEmpty, !definition.isEmpty else {
                let fallback = term.isEmpty ? try note.text() : term
                try note.replaceWith(TextNode(fallback, ""))
                continue
            }
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

import Foundation
import SwiftSoup

public enum ReaderContent {
    /// Preserve publisher feed photos when full-text extraction omits them.
    /// Resolve relative URLs before sanitizing so WebKit and the cleaner agree.
    public static func html(body: String, feed: String, baseURL: String, hiddenText: String = "") throws -> String {
        let previews = try VideoPreview.youtube(in: body + feed, baseURL: baseURL)
        let document = try SwiftSoup.parse(body, baseURL)
        try ContentRules.clean(document, url: baseURL, hiddenText: hiddenText)
        var bodyImages = Set<String>()
        for image in try document.select("img[src]") {
            let absolute = try image.absUrl("src")
            if !absolute.isEmpty {
                guard bodyImages.insert(ArticleIdentity.imageKey(absolute)).inserted else { try image.remove(); continue }
                try image.attr("src", absolute)
            }
        }
        let extractedPaths = Set(try document.select("img[src]").compactMap { image in
            ArticleIdentity.imageKey(try image.absUrl("src"))
        })
        do {
            let fallback = try SwiftSoup.parse(feed, baseURL)
            try ContentRules.clean(fallback, url: baseURL, hiddenText: hiddenText)
            var seen = Set<String>()
            var photos = ""
            for image in try fallback.select("img[src]") {
                let absolute = try image.absUrl("src")
                guard let url = URL(string: absolute), url.scheme == "https", !extractedPaths.contains(ArticleIdentity.imageKey(absolute)), seen.insert(ArticleIdentity.imageKey(absolute)).inserted else { continue }
                try image.attr("src", absolute)
                photos += try image.outerHtml()
            }
            try document.body()?.prepend(photos)
        }
        // Publisher iframes/scripts are removed. Only our validated YouTube embeds
        // are appended after cleaning, and only HTTPS video sources survive.
        let whitelist = Whitelist.relaxed()
        try whitelist.addTags("video", "source")
        try whitelist.addAttributes("video", "src", "poster", "controls", "playsinline", "preload", "width", "height")
        try whitelist.addAttributes("source", "src", "type")
        try whitelist.addProtocols("video", "src", "https")
        try whitelist.addProtocols("video", "poster", "https")
        try whitelist.addProtocols("source", "src", "https")
        let clean = try SwiftSoup.clean(document.body()?.html() ?? body, baseURL, whitelist) ?? ""
        let safe = try SwiftSoup.parse(clean)
        for video in try safe.select("video") {
            try video.attr("controls", "").attr("playsinline", "").attr("preload", "metadata")
        }
        return (try safe.body()?.html() ?? "") + previews
    }
}

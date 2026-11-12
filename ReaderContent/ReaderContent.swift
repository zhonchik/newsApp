import Foundation
import SwiftSoup

public enum ReaderContent {
    /// Preserve publisher feed photos when full-text extraction omits them.
    /// Resolve relative URLs before sanitizing so WebKit and the cleaner agree.
    public static func html(body: String, feed: String, baseURL: String, hiddenText: String = "") throws -> String {
        let document = try SwiftSoup.parse(body, baseURL)
        try ContentRules.clean(document, url: baseURL, hiddenText: hiddenText)
        for image in try document.select("img[src]") {
            let absolute = try image.absUrl("src")
            if !absolute.isEmpty { try image.attr("src", absolute) }
        }
        let extractedPaths = Set(try document.select("img[src]").compactMap { image in
            URL(string: try image.absUrl("src"))?.path
        })
        do {
            let fallback = try SwiftSoup.parse(feed, baseURL)
            var seen = Set<String>()
            var photos = ""
            for image in try fallback.select("img[src]") {
                let absolute = try image.absUrl("src")
                guard let url = URL(string: absolute), url.scheme == "https", !extractedPaths.contains(url.path), seen.insert(absolute).inserted else { continue }
                try image.attr("src", absolute)
                photos += try image.outerHtml()
            }
            try document.body()?.prepend(photos)
        }
        return try SwiftSoup.clean(document.body()?.html() ?? body, baseURL, Whitelist.relaxed()) ?? ""
    }
}

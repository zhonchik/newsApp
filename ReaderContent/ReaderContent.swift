import Foundation
import SwiftSoup

public enum ReaderContent {
    /// Preserve publisher feed photos if full-text extraction drops every image.
    /// Resolve relative URLs before sanitizing so WebKit and the cleaner agree.
    public static func html(body: String, feed: String, baseURL: String) throws -> String {
        let document = try SwiftSoup.parse(body, baseURL)
        for image in try document.select("img[src]") {
            let absolute = try image.absUrl("src")
            if !absolute.isEmpty { try image.attr("src", absolute) }
        }
        if try document.select("img[src]").isEmpty() {
            let fallback = try SwiftSoup.parse(feed, baseURL)
            var seen = Set<String>()
            var photos = ""
            for image in try fallback.select("img[src]") {
                let absolute = try image.absUrl("src")
                guard URL(string: absolute)?.scheme == "https", seen.insert(absolute).inserted else { continue }
                try image.attr("src", absolute)
                photos += try image.outerHtml()
            }
            try document.body()?.prepend(photos)
        }
        return try SwiftSoup.clean(document.body()?.html() ?? body, baseURL, Whitelist.relaxed()) ?? ""
    }
}

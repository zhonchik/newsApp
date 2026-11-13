import Foundation
import SwiftSoup

public enum TelegramContent {
    /// Telegram may include desktop/mobile copies. Keep one complete body,
    /// without deleting intentional repetitions inside the message itself.
    public static func message(in post: Element) throws -> (text: String, html: String) {
        guard let body = try post.select(".tgme_widget_message_text").first() else { return ("", "") }
        return (try body.text(), try body.html())
    }
}

public enum VideoPreview {
    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;")
    }
    public static func youtubeID(_ raw: String) -> String? {
        guard let url = URL(string: raw), ["https", "http"].contains(url.scheme ?? "") else { return nil }
        let host = url.host?.lowercased() ?? ""
        let parts = url.path.split(separator: "/").map(String.init)
        var id: String?
        if host == "youtu.be" { id = parts.first }
        else if ["youtube.com", "www.youtube.com", "m.youtube.com", "youtube-nocookie.com", "www.youtube-nocookie.com"].contains(host) {
            if parts.first == "watch" { id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "v" })?.value }
            else if parts.count > 1, ["embed", "shorts", "live"].contains(parts[0]) { id = parts[1] }
        }
        guard let id, id.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else { return nil }
        return id
    }
    public static func youtube(in html: String, baseURL: String) throws -> String {
        let doc = try SwiftSoup.parse(html, baseURL)
        var seen = Set<String>(), cards = ""
        for element in try doc.select("a[href], iframe[src]") {
            let attribute = element.tagName() == "a" ? "href" : "src"
            guard let id = youtubeID(try element.absUrl(attribute)), seen.insert(id).inserted else { continue }
            cards += card(url: "https://www.youtube.com/watch?v=" + id, poster: "https://i.ytimg.com/vi/" + id + "/hqdefault.jpg", label: "Watch on YouTube")
        }
        return cards
    }
    public static func telegram(_ post: Element, url: String) throws -> String {
        var cards = ""
        for video in try post.select("video") {
            var poster = try video.attr("poster")
            if poster.isEmpty, let container = video.parent() { poster = try backgroundPoster(container) }
            cards += card(url: url, poster: poster, label: "Watch video on Telegram")
        }
        if cards.isEmpty, !(try post.select(".tgme_widget_message_video_player, .tgme_widget_message_video_wrap")).isEmpty() {
            cards = card(url: url, poster: try backgroundPoster(post), label: "Watch video on Telegram")
        }
        return cards
    }
    private static func backgroundPoster(_ container: Element) throws -> String {
        for image in try container.select(".tgme_widget_message_video_thumb[style]") {
            let style = try image.attr("style")
            let expression = try NSRegularExpression(pattern: "url\\(['\"]?(.*?)['\"]?\\)")
            if let match = expression.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)),
               let range = Range(match.range(at: 1), in: style) { return String(style[range]) }
        }
        return ""
    }
    private static func card(url: String, poster: String, label: String) -> String {
        let image = URL(string: poster)?.scheme == "https" ? "<img src=\"\(escape(poster))\" alt=\"Video preview\">" : ""
        return "<figure><a href=\"\(escape(url))\">\(image)<br>▶ \(label)</a></figure>"
    }
}

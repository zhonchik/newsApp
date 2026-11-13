import Foundation
import SwiftSoup
import WebKit

actor FeedService {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()
    func itemsWithRetry(address: String, kind: String) async throws -> [RemoteArticle] {
        try await NetworkRetry.perform { try await items(address: address, kind: kind) }
    }

    func fetch(_ raw: String) async throws -> Data {
        guard let url = URL(string: raw), url.scheme == "https" else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 15
        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 5 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
            data.append(byte)
        }
        return data
    }
    func items(address: String, kind: String) async throws -> [RemoteArticle] {
        if kind == "telegram" {
            let channel = address.replacingOccurrences(of: "@", with: "")
            guard channel.range(of: "^[A-Za-z0-9_]{5,32}$", options: .regularExpression) != nil else { throw URLError(.badURL) }
            let data = try await fetch("https://t.me/s/" + channel)
            let doc = try SwiftSoup.parse(String(decoding: data, as: UTF8.self))
            return try doc.select(".tgme_widget_message").compactMap { post in
                let id = try post.attr("data-post")
                let message = try TelegramContent.message(in: post)
                let text = message.text
                let video = try VideoPreview.telegram(post, url: "https://t.me/" + id)
                guard !text.isEmpty || !video.isEmpty else { return nil }
                guard !id.isEmpty, let date = Self.date(try post.select("time").attr("datetime")) else { return nil }
                return RemoteArticle(id: id, title: text.isEmpty ? "Telegram video" : String(text.prefix(100)), url: "https://t.me/" + id, text: text, published: date, html: message.html + (try Self.telegramImages(post)) + video)
            }
        }
        let data = try await fetch(address)
        return try FeedParser.parse(data)
    }
    func articleText(url: String) async throws -> String {
        let data = try await fetch(url)
        let page = String(decoding: data, as: UTF8.self)
        if let body = try ContentRules.articleBody(page: page, url: url) { return body }
        guard let resource = Bundle.main.url(forResource: "Readability", withExtension: "js") else { throw URLError(.fileDoesNotExist) }
        let library = try String(contentsOf: resource, encoding: .utf8)
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [page]), encoding: .utf8)!
        let script = library + "\nconst doc = new DOMParser().parseFromString(\(encoded)[0], 'text/html'); const base = doc.createElement('base'); base.href = document.baseURI; doc.head.appendChild(base); new Readability(doc).parse()?.content || '';"
        let extractor = await ArticleExtractor()
        return try await extractor.extract(script: script, url: url)
    }
    private static func telegramImages(_ post: Element) throws -> String {
        var html = ""
        for photo in try post.select(".tgme_widget_message_photo_wrap") {
            let style = try photo.attr("style")
            if let expression = try? NSRegularExpression(pattern: "url\\(['\"]?(.*?)['\"]?\\)"),
               let match = expression.firstMatch(in: style, range: NSRange(style.startIndex..., in: style)),
               let range = Range(match.range(at: 1), in: style) {
                let source = String(style[range]).replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
                html += "<p><img src=\"\(source)\"></p>"
            }
        }
        return html
    }
    static func date(_ raw: String) -> Date? {
        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions.insert(.withFractionalSeconds)
        if let date = iso.date(from: raw) { return date }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss Z", "yyyy-MM-dd'T'HH:mm:ssZ"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return nil
    }
}

final class FeedParser: NSObject, XMLParserDelegate {
    private var items: [RemoteArticle] = []
    private var fields: [String: String] = [:]
    private var element = ""
    private var active = false
    static func parse(_ data: Data) throws -> [RemoteArticle] {
        let delegate = FeedParser(), parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse() else { throw parser.parserError ?? URLError(.cannotParseResponse) }
        return delegate.items
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        element = name
        if name == "item" || name == "entry" { active = true; fields = [:] }
        if active, ["media:content", "media:thumbnail", "enclosure"].contains(name),
           let image = attributes["url"], name != "enclosure" || (attributes["type"] ?? "").hasPrefix("image/") {
            fields["image"] = image
        }
        if active, name == "link", let href = attributes["href"], attributes["rel"] == nil || attributes["rel"] == "alternate" { fields["link"] = href }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if active { fields[element, default: ""] += string } }
    func parser(_ parser: XMLParser, foundCDATA data: Data) { self.parser(parser, foundCharacters: String(decoding: data, as: UTF8.self)) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard name == "item" || name == "entry" else { return }
        active = false
        func field(_ key: String) -> String { fields[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines) }
        let url = field("link"), id = field("guid").isEmpty ? field("id") : field("guid")
        guard let date = FeedService.date(["pubDate", "published", "updated", "dc:date"].map(field).first(where: { !$0.isEmpty }) ?? ""), !url.isEmpty else { return }
        var html = ["content:encoded", "content", "description", "summary"].map(field).first(where: { !$0.isEmpty }) ?? ""
        if !field("image").isEmpty, !html.contains("<img") {
            let image = field("image").replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            html = "<img src=\"\(image)\">" + html
        }
        let text = (try? SwiftSoup.parse(html).text()) ?? html
        items.append(RemoteArticle(id: id.isEmpty ? url : id, title: field("title"), url: url, text: text, published: date, html: html))
    }
}

@MainActor final class ArticleExtractor: NSObject, WKNavigationDelegate {
    private var webView: WKWebView!
    private var continuation: CheckedContinuation<String, Error>?
    private var script = ""
    func extract(script: String, url: String) async throws -> String {
        self.script = script
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: .zero, configuration: configuration); webView.navigationDelegate = self
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // Only this empty document is loaded. Publisher HTML is parsed as an inert DOM;
            // its scripts, images and trackers are never loaded into the web view.
            webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: url))
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(script) { result, error in
            if let error { self.continuation?.resume(throwing: error) }
            else { self.continuation?.resume(returning: (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)) }
            self.continuation = nil
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}

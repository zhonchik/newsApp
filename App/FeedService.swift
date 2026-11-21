#if SWIFT_PACKAGE
import ReaderContent
#endif
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
        let telegram = ContentRules.isTelegram(url)
        let data = try await fetch(telegram ? url + "?embed=1" : url)
        let page = String(decoding: data, as: UTF8.self)
        if telegram {
            let document = try SwiftSoup.parse(page, url)
            guard let post = try document.select(".tgme_widget_message").first() else { throw URLError(.cannotParseResponse) }
            let message = try TelegramContent.message(in: post)
            let html = message.html + (try Self.telegramImages(post)) + (try VideoPreview.telegram(post, url: url))
            guard !html.isEmpty else { throw URLError(.cannotParseResponse) }
            return html
        }
        return try await Self.extractArticle(page: page, url: url)
    }

    static func extractArticle(page: String, url: String) async throws -> String {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let resource = bundle.url(forResource: "Readability", withExtension: "js") else { throw URLError(.fileDoesNotExist) }
        let library = try String(contentsOf: resource, encoding: .utf8)
        let encoded = String(data: try JSONSerialization.data(withJSONObject: [page, ContentRules.adSelector, ContentRules.bannerLinkPattern]), encoding: .utf8)!
        let script = library + """

        const [page, adSelector, bannerLinkPattern] = \(encoded);
        const doc = new DOMParser().parseFromString(page, 'text/html');
        const base = doc.createElement('base');
        base.href = document.baseURI;
        doc.head.appendChild(base);
        for (const ad of doc.querySelectorAll(adSelector)) ad.remove();
        const bannerLink = new RegExp(bannerLinkPattern, 'i');
        for (const link of doc.querySelectorAll('a[href]:has(img)')) {
          if (!link.textContent.trim() && bannerLink.test(link.getAttribute('href'))) link.remove();
        }
        // Readability can merge neighboring stories when they share the same layout.
        const normalizeTitle = value => value?.replace(/\\s+/g, ' ').trim();
        const pageTitles = new Set([
          doc.querySelector('meta[property="og:title"]')?.content,
          doc.querySelector('meta[name="twitter:title"]')?.content,
          doc.title
        ].map(normalizeTitle).filter(Boolean));
        const topHeading = 'h1, [role="heading"][aria-level="1"]';
        const articleElement = 'article, [role="article"]';
        const headings = [...doc.querySelectorAll(topHeading)]
          .filter(heading => pageTitles.has(normalizeTitle(heading.textContent)));
        if (headings.length === 1) {
          const heading = headings[0];
          const article = heading.closest(articleElement) || heading.closest('section');
          const next = article?.nextElementSibling;
          if (article?.querySelector('p') && next?.matches(articleElement + ', section') && next.querySelector('p')) {
            // Some layouts use the main headline's classes on a plain element in the preview.
            const classes = [...heading.classList];
            const hasOtherTitle = [...next.querySelectorAll(topHeading + ', div[class]')].some(candidate => {
              const title = normalizeTitle(candidate.textContent);
              if (!title || pageTitles.has(title)) return false;
              if (candidate.matches(topHeading)) return true;
              return classes.length > 0 && candidate.classList.length === classes.length &&
                classes.every(name => candidate.classList.contains(name)) && !candidate.querySelector('p');
            });
            if (hasOtherTitle) next.remove();
          }
        }
        // Keep inline labels and inert definitions together through extraction.
        for (const template of doc.querySelectorAll('template')) {
          const component = template.parentElement;
          const label = component?.getAttribute('text')?.trim();
          if (!label || !component.localName.includes('-')) continue;
          const definition = doc.createElement('dfn');
          definition.textContent = label;
          definition.title = template.content.textContent.trim();
          component.replaceWith(definition);
        }
        const heading = headings.length === 1 ? headings[0] : doc.querySelector('h1');
        const deck = heading?.nextElementSibling;
        const summary = doc.querySelector('meta[property="og:description"]')?.content;
        const author = doc.querySelector('meta[name="author"]')?.content?.trim();
        const followedByAuthor = author && normalizeTitle(deck?.nextElementSibling?.textContent) === normalizeTitle(author);
        const subtitle = deck && (deck.matches('[itemprop="alternativeHeadline"], .subtitle, .subheadline') ||
          (deck.matches('p') && (followedByAuthor || normalizeTitle(deck.textContent) === normalizeTitle(summary))))
          ? deck.textContent.trim() : '';
        // A shortcut hint inside a conditional UI element belongs to the source site's controls.
        for (const hint of doc.querySelectorAll('[v-if], [v-show], [hidden], [aria-hidden="true"]')) {
          if (!hint.childElementCount && hint.textContent.trim().length <= 200 &&
              /(?:Ctrl|Control|Cmd|Command)\\s*\\+\\s*(?:Enter|Return)/i.test(hint.textContent)) hint.remove();
        }
        // Recover figures from inert media components that supply image records as JSON.
        const scope = heading?.closest('article, section, main') || doc.body;
        for (const element of scope.querySelectorAll('*')) {
          if (!(element instanceof HTMLUnknownElement) && !element.localName.includes('-')) continue;
          if (element.childElementCount || element.textContent.trim()) continue;
          for (const attr of element.attributes) {
            if (!attr.value.trimStart().startsWith('{')) continue;
            let data;
            try { data = JSON.parse(attr.value); } catch { continue; }
            const items = data.items || data.images;
            if (!Array.isArray(items)) continue;
            const figures = [];
            for (const item of items) {
              const src = item?.img || item?.src || item?.image;
              const label = item?.caption || item?.subtitle || item?.description;
              if (typeof src !== 'string' || typeof label !== 'string') continue;
              let url;
              try { url = new URL(src, base.href); } catch { continue; }
              if (url.protocol !== 'https:') continue;
              const fig = doc.createElement('figure');
              const img = doc.createElement('img');
              img.src = url.href;
              const caption = doc.createElement('figcaption');
              const text = new DOMParser().parseFromString(label, 'text/html').body.textContent.trim();
              const credit = Object.entries(item).find(([key, value]) =>
                /^(?:credit|copyright)/i.test(key) && typeof value === 'string' && value.trim() && !/^https?:/i.test(value));
              caption.textContent = [text, credit?.[1]].filter(Boolean).join(' — ');
              fig.append(img, caption);
              figures.push(fig);
            }
            if (figures.length) { element.replaceWith(...figures); break; }
          }
        }
        const main = doc.querySelector('main, [role="main"], article');
        const imageFallback = main?.querySelector('img') ? main.innerHTML : '';
        const parsed = new Readability(doc).parse();
        const result = doc.createElement('div');
        result.innerHTML = parsed?.content || imageFallback;
        if (result.childNodes.length) {
          const header = doc.createElement('header');
          for (const value of [subtitle, author || parsed?.byline]) {
            const text = value?.trim();
            if (!text || [...header.children].some(line => line.textContent === text)) continue;
            const existing = [...result.querySelectorAll('p, div, [rel~=author]')].find(node =>
              !node.querySelector('img, figure, video') && normalizeTitle(node.textContent) === normalizeTitle(text));
            if (existing) existing.remove();
            const line = doc.createElement('p');
            line.textContent = text;
            header.append(line);
          }
          if (header.childElementCount) result.prepend(header);
        }
        result.innerHTML;
        """
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
    private var webView: WKWebView?
    private var continuation: CheckedContinuation<String, Error>?
    private var timeout: Task<Void, Never>?
    private var script = ""
    func extract(script: String, url: String) async throws -> String {
        self.script = script
        let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = .nonPersistent()
        let view = WKWebView(frame: .zero, configuration: configuration)
        webView = view; view.navigationDelegate = self
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                timeout = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(20)) } catch { return }
                    self?.finish(.failure(URLError(.timedOut)))
                }
                view.loadHTMLString("<html><body></body></html>", baseURL: URL(string: url))
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel(); timeout = nil
        webView?.stopLoading(); webView?.navigationDelegate = nil; webView = nil
        continuation.resume(with: result)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript(script) { result, error in
            if let error { self.finish(.failure(error)) }
            else { self.finish(.success((result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines))) }
        }
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { finish(.failure(error)) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { finish(.failure(URLError(.cannotLoadFromNetwork))) }
}

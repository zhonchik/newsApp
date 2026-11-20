#if SWIFT_PACKAGE
import ReaderContent
#endif
import Foundation
import CryptoKit
import WebKit
import SwiftSoup

actor MediaCache {
    static let shared = MediaCache()
    struct Entry: Codable, Sendable { let file: URL; let mime: String; let size: Int }
    private var pending: [URL: Task<Entry, Error>] = [:]
    private let directory: URL
    private let limitOverride: Int?
    init(directory: URL? = nil, limitBytes: Int? = nil, session: URLSession? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ReaderMedia", isDirectory: true)
        limitOverride = limitBytes
        self.session = session ?? Self.makeSession()
    }
    private let session: URLSession
    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }
    private struct FormattedBody: Codable {
        let signature: Data
        let html: String
        let cachedMedia: [String: Bool]
    }
    private var lastBody: FormattedBody?
    private var bodyNeedsSave = false
    private var bodyFile: URL { directory.appendingPathComponent("last-formatted-body") }

    func formattedBody(_ article: ReaderDocument, hiddenText: String) throws -> (html: String, reused: Bool) {
        // Increment the format version when changing sanitization or media markup.
        var hash = SHA256()
        for value in ["reader-body-1", String(ContentRules.revision), article.key, article.url,
                      hiddenText, article.text, article.html, article.feedHTML] {
            let bytes = Data(value.utf8)
            withUnsafeBytes(of: UInt64(bytes.count).bigEndian) { hash.update(bufferPointer: $0) }
            hash.update(data: bytes)
        }
        let signature = Data(hash.finalize())
        let saved = lastBody ?? (try? Data(contentsOf: bodyFile)).flatMap { try? JSONDecoder().decode(FormattedBody.self, from: $0) }
        if let saved, saved.signature == signature, saved.cachedMedia.allSatisfy({ hasCachedMedia($0.key) == $0.value }) {
            lastBody = saved
            return (saved.html, true)
        }

        let text = article.text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
        let fallback = "<p>" + text.replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        let source = article.html.isEmpty && article.text.isEmpty ? article.feedHTML : article.html
        let clean = try ReaderContent.html(body: source.isEmpty ? fallback : source, feed: article.feedHTML, baseURL: article.url, hiddenText: hiddenText)
        let doc = try SwiftSoup.parseBodyFragment(clean)
        let media = try rewriteMedia(in: doc)
        let html = try doc.body()?.html() ?? clean
        bodyNeedsSave = true
        lastBody = FormattedBody(signature: signature, html: html, cachedMedia: media)
        return (html, false)
    }

    func saveFormattedBody() throws {
        guard bodyNeedsSave, let body = lastBody else { return }
        bodyNeedsSave = false
        let data = try JSONEncoder().encode(body)
        guard data.count <= min(limit / 8, 4 * 1024 * 1024) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: bodyFile, options: .atomic)
        try trim()
    }

    func rewrite(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        _ = try rewriteMedia(in: doc)
        return try doc.outerHtml()
    }
    private func rewriteMedia(in doc: Document) throws -> [String: Bool] {
        var media: [String: Bool] = [:]
        for image in try doc.select("img[src], video[poster]") {
            let attr = image.tagName() == "video" ? "poster" : "src"
            if let raw = MediaURL.resolve(try image.attr(attr)), let source = MediaRequest.cachedURL(raw) {
                let cached = hasCachedMedia(raw)
                media[raw] = cached
                if cached { try image.attr(attr, source) }
                else {
                    try image.removeAttr(attr)
                    try image.attr("data-reader-" + attr, source)
                }
            }
            if image.tagName() == "img" { try image.attr("loading", "lazy").attr("decoding", "async") }
        }
        for video in try doc.select("video[src], source[src]") {
            let raw = try video.attr("src")
            guard let cached = MediaRequest.cachedURL(raw) else { continue }
            let available = hasCachedMedia(raw)
            media[raw] = available
            if available {
                try video.attr("src", cached)
            }
        }
        for video in try doc.select("video") { try video.attr("preload", "none") }
        for frame in try doc.select("iframe[src]") {
            let source = try frame.attr("src")
            try frame.removeAttr("src")
            try frame.attr("data-reader-src", source)
        }
        return media
    }
    private func hasCachedMedia(_ url: String) -> Bool {
        let name = SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: file.path)
            && FileManager.default.fileExists(atPath: file.appendingPathExtension("json").path)
    }
    func entry(for requestedURL: URL, force: Bool = false) async throws -> Entry {
        guard let normalized = MediaURL.resolve(requestedURL.absoluteString), let url = URL(string: normalized) else { throw URLError(.badURL) }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        let metadata = file.appendingPathExtension("json")
        if !force, let data = try? Data(contentsOf: metadata), let entry = try? JSONDecoder().decode(Entry.self, from: data),
           FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            // App updates can move the sandbox; never reuse an old absolute path.
            return Entry(file: file, mime: entry.mime, size: entry.size)
        }
        if let task = pending[url] { return try await task.value }
        // A forced refresh keeps the previous offline copy until replacement succeeds.
        if !force {
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.removeItem(at: metadata)
        }
        let task = Task { try await self.download(url, file: file, metadata: metadata) }
        pending[url] = task
        defer { pending[url] = nil }
        return try await task.value
    }
    private func download(_ url: URL, file: URL, metadata: URL) async throws -> Entry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (temporary, response) = try await session.download(for: request, delegate: MediaDownloadLimit())
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let mime = response.mimeType, mime.hasPrefix("image/") || mime.hasPrefix("video/") else { throw URLError(.badServerResponse) }
        let count = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard count > 0, count <= min(80 * 1024 * 1024, limit - 4096) else { throw URLError(.dataLengthExceedsMaximum) }
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try FileManager.default.replaceItemAt(file, withItemAt: temporary)
        } else { try FileManager.default.moveItem(at: temporary, to: file) }
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        let entry = Entry(file: file, mime: mime, size: count)
        do { try JSONEncoder().encode(entry).write(to: metadata, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        try trim()
        return entry
    }
    static let limitKey = "readerCacheLimitMB"
    private var limit: Int {
        if let limitOverride { return limitOverride }
        let stored = UserDefaults.standard.integer(forKey: Self.limitKey)
        return max(64, stored == 0 ? 512 : min(8192, stored)) * 1024 * 1024
    }
    private func articleFile(_ key: String) -> URL {
        let name = SHA256.hash(data: Data(("article:" + key).utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name)
    }
    private static let lastArticleKey = "lastCachedArticleLink"
    static func forgetLaunchLink() { UserDefaults.standard.removeObject(forKey: lastArticleKey) }
    func remember(_ link: ArticleLink) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(link), forKey: Self.lastArticleKey)
    }
    func launchDocument() -> ReaderDocument? {
        guard let data = UserDefaults.standard.data(forKey: Self.lastArticleKey),
              let link = try? JSONDecoder().decode(ArticleLink.self, from: data),
              let content = article(link.key) else { return nil }
        return ReaderDocument(link, content: content)
    }
    func article(_ key: String) -> CachedArticle? {
        let file = articleFile(key)
        guard let data = try? Data(contentsOf: file), let article = try? JSONDecoder().decode(CachedArticle.self, from: data) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return article
    }
    func storeArticle(_ article: CachedArticle, key: String) throws {
        try writeArticle(article, key: key)
        try trim()
    }
    private func writeArticle(_ article: CachedArticle, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(article).write(to: articleFile(key), options: .atomic)
    }

    func migrateBatch(_ bodies: [(String, CachedArticle)]) throws -> Set<String> {
        for (key, body) in bodies {
            try Task.checkCancellation()
            if article(key) == nil { try writeArticle(body, key: key) }
        }
        try trim()
        return Set(bodies.compactMap { key, _ in
            FileManager.default.fileExists(atPath: articleFile(key).path) ? key : nil
        })
    }
    /// Subscription refresh warms images/posters, never video data.
    func prefetchImages(_ html: String, feed: String = "", baseURL: String, force: Bool = false) async throws {
        let fallback = try SwiftSoup.parse(feed, baseURL)
        let feedSources = try fallback.select("img[src]").compactMap { image in
            MediaURL.resolve(try image.attr("src"), baseURL: baseURL)
        }
        let doc = try SwiftSoup.parse(html + feed, baseURL)
        var urls = Set<URL>()
        for image in try doc.select("img[src], video[poster]") {
            let isImage = image.tagName() == "img"
            guard let source = MediaURL.resolve(try image.attr(isImage ? "src" : "poster"), baseURL: baseURL) else { continue }
            let original = isImage ? MediaURL.originalImage(for: source, in: feedSources) : nil
            if let url = URL(string: original ?? source) { urls.insert(url) }
        }
        // Bound concurrency and memory; URLSession downloads to temporary files.
        var failure: Error?
        for url in urls.sorted(by: { $0.absoluteString < $1.absoluteString }) {
            try Task.checkCancellation()
            do { _ = try await entry(for: url, force: force) }
            catch { failure = error }
        }
        if let failure { throw failure }
    }
    func usage() throws -> Int {
        try trim()
        return try files().reduce(0) { $0 + $1.bytes }
    }
    private func files() throws -> [CachePolicy.Item] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])
        // Metadata is counted with its payload, so the displayed size includes sidecars.
        return try urls.filter { $0.pathExtension.isEmpty }.map { url in
            let value = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let metadata = try? url.appendingPathExtension("json").resourceValues(forKeys: [.fileSizeKey])
            return CachePolicy.Item(key: url.lastPathComponent, bytes: (value.fileSize ?? 0) + (metadata?.fileSize ?? 0), accessed: value.contentModificationDate ?? .distantPast)
        }
    }
    func trim() throws {
        for name in CachePolicy.evictions(try files(), limit: limit) {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.removeItem(at: file)
            let metadata = file.appendingPathExtension("json")
            if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
        }
    }

}

/// Serializes stop and callbacks: WebKit must never receive a callback after stop.
private final class MediaLoad: @unchecked Sendable {
    let request: URLRequest
    private let task: WKURLSchemeTask
    private let lock = NSRecursiveLock()
    private var stopped = false
    init(_ task: WKURLSchemeTask) { self.task = task; request = task.request }
    func stop() { lock.lock(); stopped = true; lock.unlock() }
    func send(_ callback: (WKURLSchemeTask) -> Void) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !stopped else { return false }
        callback(task); return true
    }
}

final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private var loads: [ObjectIdentifier: MediaLoad] = [:]
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        let id = ObjectIdentifier(urlSchemeTask)
        let load = MediaLoad(urlSchemeTask)
        lock.lock(); loads[id] = load; lock.unlock()
        Task.detached(priority: .utility) { [self] in
            defer { Task { @MainActor in self.remove(id) } }
            do {
                guard let url = load.request.url, let remote = MediaRequest.remoteURL(url) else { throw URLError(.badURL) }
                let entry = try await MediaCache.shared.entry(for: remote)
                let requested = load.request.value(forHTTPHeaderField: "Range")
                guard let range = MediaRequest.range(requested, size: entry.size) else {
                    let response = HTTPURLResponse(url: url, statusCode: 416, httpVersion: "HTTP/1.1", headerFields: ["Content-Range": "bytes */\(entry.size)"])!
                    _ = load.send { $0.didReceive(response); $0.didFinish() }; return
                }
                var headers = ["Content-Type": entry.mime, "Content-Length": "\(range.count)", "Accept-Ranges": "bytes", "Access-Control-Allow-Origin": "*"]
                if requested != nil { headers["Content-Range"] = "bytes \(range.lowerBound)-\(range.upperBound - 1)/\(entry.size)" }
                let response = HTTPURLResponse(url: url, statusCode: requested == nil ? 200 : 206, httpVersion: "HTTP/1.1", headerFields: headers)!
                guard load.send({ $0.didReceive(response) }) else { return }
                let file = try FileHandle(forReadingFrom: entry.file)
                defer { try? file.close() }
                try file.seek(toOffset: UInt64(range.lowerBound))
                var remaining = range.count
                while remaining > 0 {
                    let data = try file.read(upToCount: min(64 * 1024, remaining)) ?? Data()
                    guard !data.isEmpty else { throw URLError(.cannotDecodeContentData) }
                    guard load.send({ $0.didReceive(data) }) else { return }
                    remaining -= data.count
                }
                _ = load.send { $0.didFinish() }
            } catch { _ = load.send { $0.didFailWithError(error) } }
        }
    }
    private func remove(_ id: ObjectIdentifier) { lock.lock(); loads[id] = nil; lock.unlock() }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock(); let load = loads.removeValue(forKey: ObjectIdentifier(urlSchemeTask)); lock.unlock()
        load?.stop()
    }
}

private final class MediaDownloadLimit: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let limit: Int64 = 80 * 1024 * 1024
        if totalBytesWritten > limit || totalBytesExpectedToWrite > limit { downloadTask.cancel() }
    }
}

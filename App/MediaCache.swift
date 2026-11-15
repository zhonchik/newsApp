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
    func rewrite(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        for image in try doc.select("img[src], video[poster]") {
            let attr = image.tagName() == "video" ? "poster" : "src"
            if let source = MediaRequest.cachedURL(try image.attr(attr)) { try image.attr(attr, source) }
            if image.tagName() == "img" { try image.attr("loading", "lazy").attr("decoding", "async") }
        }
        for video in try doc.select("video[src], source[src]") {
            let raw = try video.attr("src")
            guard let cached = MediaRequest.cachedURL(raw) else { continue }
            let name = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).appendingPathExtension("json").path) {
                try video.attr("src", cached)
            }
        }
        for video in try doc.select("video") { try video.attr("preload", "none") }
        return try doc.outerHtml()
    }
    func entry(for url: URL, force: Bool = false) async throws -> Entry {
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
    func article(_ key: String) -> CachedArticle? {
        let file = articleFile(key)
        guard let data = try? Data(contentsOf: file), let article = try? JSONDecoder().decode(CachedArticle.self, from: data) else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return article
    }
    func storeArticle(_ article: CachedArticle, key: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(article).write(to: articleFile(key), options: .atomic)
        try trim()
    }
    /// Subscription refresh warms images/posters, never video data.
    func prefetchImages(_ html: String, baseURL: String, force: Bool = false) async throws {
        let doc = try SwiftSoup.parse(html, baseURL)
        var urls = Set<URL>()
        for image in try doc.select("img[src], video[poster]") {
            let attr = image.tagName() == "video" ? "poster" : "src"
            if let url = URL(string: try image.absUrl(attr)), url.scheme == "https" { urls.insert(url) }
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
            defer { remove(id) }
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

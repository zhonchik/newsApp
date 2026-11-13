import Foundation
import CryptoKit
import WebKit
import SwiftSoup

actor MediaCache {
    static let shared = MediaCache()
    struct Entry: Codable, Sendable { let file: URL; let mime: String; let size: Int }
    private var pending: [URL: Task<Entry, Error>] = [:]
    private let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ReaderMedia", isDirectory: true)
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 180
        return URLSession(configuration: config)
    }()
    func rewrite(_ html: String) throws -> String {
        let doc = try SwiftSoup.parse(html)
        for image in try doc.select("img[src], video[poster]") {
            let attr = image.tagName() == "video" ? "poster" : "src"
            if let source = MediaRequest.cachedURL(try image.attr(attr)) { try image.attr(attr, source) }
            if image.tagName() == "img" { try image.attr("loading", "lazy").attr("decoding", "async") }
        }
        for video in try doc.select("video[src], source[src]") {
            let raw = try video.attr("src")
            guard let remote = URL(string: raw), let cached = MediaRequest.cachedURL(raw) else { continue }
            let name = SHA256.hash(data: Data(raw.utf8)).map { String(format: "%02x", $0) }.joined()
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path),
               FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).appendingPathExtension("json").path) {
                try video.attr("src", cached)
            } else {
                // Stream immediately over HTTPS on first play while warming disk cache.
                Task(priority: .utility) { _ = try? await self.entry(for: remote) }
            }
        }
        return try doc.outerHtml()
    }
    func entry(for url: URL) async throws -> Entry {
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        let metadata = file.appendingPathExtension("json")
        if let data = try? Data(contentsOf: metadata), let entry = try? JSONDecoder().decode(Entry.self, from: data),
           FileManager.default.fileExists(atPath: entry.file.path) {
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
            return entry
        }
        if let task = pending[url] { return try await task.value }
        // Recover a partial entry if the process stopped between file and metadata writes.
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: metadata)
        let task = Task { try await self.download(url, file: file, metadata: metadata) }
        pending[url] = task
        defer { pending[url] = nil }
        return try await task.value
    }
    private func download(_ url: URL, file: URL, metadata: URL) async throws -> Entry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (temporary, response) = try await session.download(from: url, delegate: MediaDownloadLimit())
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let mime = response.mimeType, mime.hasPrefix("image/") || mime.hasPrefix("video/") else { throw URLError(.badServerResponse) }
        let count = (try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard count > 0, count <= 80 * 1024 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        try FileManager.default.moveItem(at: temporary, to: file)
        let entry = Entry(file: file, mime: mime, size: count)
        do { try JSONEncoder().encode(entry).write(to: metadata, options: .atomic) }
        catch { try? FileManager.default.removeItem(at: file); throw error }
        trim(except: file)
        return entry
    }
    private func trim(except current: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.filter { $0.pathExtension.isEmpty }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for (url, bytes, _) in entries where size > 512 * 1024 * 1024 && url != current {
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.removeItem(at: url.appendingPathExtension("json"))
            size -= bytes
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

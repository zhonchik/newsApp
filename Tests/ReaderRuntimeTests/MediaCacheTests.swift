import XCTest
import CryptoKit
@testable import ReaderRuntime

final class MediaCacheTests: XCTestCase {
    func testFailedForcedRefreshKeepsCachedImageAndRepairsSandboxPath() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = URL(string: "https://example.com/image.jpg")!
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(name)
        let original = Data([1, 2, 3, 4])
        try original.write(to: file)
        let entry = MediaCache.Entry(file: URL(fileURLWithPath: "/old-sandbox/image"), mime: "image/jpeg", size: original.count)
        try JSONEncoder().encode(entry).write(to: file.appendingPathExtension("json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = MediaCache(directory: root, limitBytes: 8192, session: session)
        do {
            _ = try await cache.entry(for: url, force: true)
            XCTFail("Expected offline refresh to fail")
        } catch { }
        let cached = try await cache.entry(for: url)
        XCTAssertEqual(cached.file, file)
        XCTAssertEqual(try Data(contentsOf: cached.file), original)
    }
    func testMalformedFeedImageUsesCorrectCachedFileWithoutNetwork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let correct = "https://cdn.example.com/gallery/2026/photo.jpg"
        let malformed = "https://cdn.example.com" + correct
        let name = SHA256.hash(data: Data(correct.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: file)
        try JSONEncoder().encode(MediaCache.Entry(file: file, mime: "image/jpeg", size: 3)).write(to: file.appendingPathExtension("json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = MediaCache(directory: root, limitBytes: 8192, session: session)
        try await cache.prefetchImages("<img src='\(malformed)'>", baseURL: "https://publisher.example/news/story")
        let entry = try await cache.entry(for: XCTUnwrap(URL(string: malformed)))
        XCTAssertEqual(entry.file, file)
        let rendered = try await cache.rewrite("<img src='\(malformed)'>")
        XCTAssertTrue(rendered.contains("reader-media://cdn.example.com/gallery/2026/photo.jpg"))
        XCTAssertFalse(rendered.contains("comhttps"))
    }
    func testPrefetchUsesCachedOriginalForArticleRendition() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = "https://cdn.example.com/photos/image.jpg"
        let name = SHA256.hash(data: Data(original.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = root.appendingPathComponent(name)
        try Data([1, 2, 3]).write(to: file)
        let entry = MediaCache.Entry(file: file, mime: "image/jpeg", size: 3)
        try JSONEncoder().encode(entry).write(to: file.appendingPathExtension("json"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OfflineProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = MediaCache(directory: root, limitBytes: 8192, session: session)
        try await cache.prefetchImages(
            "<img src='https://cdn.example.com/render/400x0/photos/image.jpg'>",
            feed: "<img src='\(original)'>",
            baseURL: "https://publisher.example.com/story"
        )
    }
    func testOpeningVideoDocumentDoesNotDownloadVideo() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedVideoProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = MediaCache(directory: root, limitBytes: 8192, session: session)
        let html = try await cache.rewrite("<video src='https://example.com/video.mp4' preload='metadata' controls></video>")
        XCTAssertTrue(html.contains("preload=\"none\""))
        XCTAssertTrue(html.contains("https://example.com/video.mp4"))
        try await Task.sleep(for: .milliseconds(200))
        let size = try await cache.usage()
        XCTAssertEqual(size, 0)
    }
}
private class OfflineProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
private final class UnexpectedVideoProtocol: OfflineProtocol {
    override func startLoading() {
        XCTFail("Opening an article must not start a video download")
        super.startLoading()
    }
}

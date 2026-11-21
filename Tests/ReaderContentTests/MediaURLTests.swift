import XCTest
@testable import ReaderContent

final class MediaURLTests: XCTestCase {
    private let path = "/gallery/2026/photo.jpg"
    private var correct: String { "https://cdn.example.com" + path }
    private var malformed: String { "https://cdn.example.com" + correct }
    func testReportedFeedURLRepairsToOriginalImageAndIsIdempotent() {
        XCTAssertEqual(MediaURL.resolve(malformed), correct)
        XCTAssertEqual(MediaURL.resolve(correct), correct)
        XCTAssertEqual(MediaURL.resolve("  " + malformed + "\n"), correct)
    }
    func testCachedHTMLAndFeedFallbackAreRepairedAndDeduplicated() throws {
        let html = try ReaderContent.html(body: "<p>Story</p><img src='\(malformed)'>", feed: "<img src='\(correct)'>", baseURL: "https://publisher.example/news/story")
        XCTAssertTrue(html.contains(correct))
        XCTAssertFalse(html.contains("comhttps"))
        XCTAssertEqual(html.components(separatedBy: "<img").count - 1, 1)
        let fallback = try ReaderContent.html(body: "<p>Story</p>", feed: "<img src='\(malformed)'>", baseURL: "https://publisher.example/news/story")
        XCTAssertTrue(fallback.contains(correct))
        XCTAssertFalse(fallback.contains("comhttps"))
    }
    func testCacheSchemeUsesRepairedRemoteURL() throws {
        let cached = try XCTUnwrap(MediaRequest.cachedURL(malformed))
        XCTAssertEqual(MediaRequest.remoteURL(try XCTUnwrap(URL(string: cached)))?.absoluteString, correct)
    }
    func testRelativeImagesAndLegitimateNestedURLsArePreserved() {
        XCTAssertEqual(MediaURL.resolve("//cdn.example.com/image.jpg", baseURL: "https://example.com/story"), "https://cdn.example.com/image.jpg")
        XCTAssertEqual(MediaURL.resolve("/image.jpg", baseURL: "https://example.com/story"), "https://example.com/image.jpg")
        let proxy = "https://cdn.example.com/proxy/https://origin.example.com/image.jpg?next=https://other.example.com"
        XCTAssertEqual(MediaURL.resolve(proxy), proxy)
    }
    func testOriginalImageRequiresMatchingFeedPathAndOrigin() {
        let rendition = "https://cdn.example.com/render/400x0/photos/image.jpg"
        let unrelated = [
            "https://other.example.com/photos/image.jpg",
            "https://cdn.example.com:8443/photos/image.jpg",
            "https://cdn.example.com/other/image.jpg",
            "https://cdn.example.com/photos/other.jpg"
        ]
        XCTAssertNil(MediaURL.originalImage(for: rendition, in: unrelated))
        XCTAssertNil(MediaURL.originalImage(for: "https://cdn.example.com/adjacent/photos/image.jpg",
                                            in: ["https://cdn.example.com/photos/image.jpg"]))
    }
    func testDoesNotGuessOtherConcatenatedOriginsOrAllowUnsafeSchemes() {
        XCTAssertNil(MediaURL.resolve("https://other.examplehttps://cdn.example.com/image.jpg"))
        XCTAssertNil(MediaURL.resolve("javascript:alert(1)"))
        XCTAssertNil(MediaURL.resolve("file:///tmp/image.jpg"))
        XCTAssertNil(MediaURL.resolve("http://cdn.example.com/image.jpg"))
    }
}

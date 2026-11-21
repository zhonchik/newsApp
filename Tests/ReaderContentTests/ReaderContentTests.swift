import XCTest
@testable import ReaderContent

final class ReaderContentTests: XCTestCase {
    let base = "https://publisher.example/news/article"
    let feed = "<img src='https://cdn.example.com/photos/cover.jpg'><p>Summary</p>"
    func testFeedPhotoSurvivesFullTextReplacement() throws {
        let result = try ReaderContent.html(body: "<p>Complete article</p>", feed: feed, baseURL: base)
        XCTAssertTrue(result.contains("cover.jpg"))
        XCTAssertTrue(result.contains("Complete article"))
        XCTAssertFalse(result.contains("Summary"))
    }
    func testExtractedPhotoAvoidsDuplicateFeedPhoto() throws {
        let result = try ReaderContent.html(body: "<img src='//images.example/photos/cover.jpg'><p>Article</p>", feed: feed, baseURL: base)
        XCTAssertTrue(result.contains("https://images.example/"))
        XCTAssertFalse(result.contains("https://cdn.example.com/"))
    }
    func testLeadPhotoSurvivesUnrelatedExtractedImages() throws {
        let photo = "https://cdn.example.com/photos/cover-share.png"
        let result = try ReaderContent.html(body: "<img src='https://assets.example/logo.svg'><p>Full story</p>", feed: "<img src='\(photo)'><p>Summary</p>", baseURL: "https://publisher.example/news/article")
        XCTAssertTrue(result.contains(photo))
        XCTAssertTrue(result.contains("Full story"))
        XCTAssertFalse(result.contains("Summary"))
    }
    func testCaptionedLeadAndBylinePrecedeSupplementaryFeedImage() throws {
        let body = "<header><p>By Alex</p></header><figure><img src='/river.jpg'><figcaption>Upper river</figcaption></figure><p>Full story</p>"
        let result = try ReaderContent.html(body: body, feed: feed, baseURL: base)
        let markers = ["By Alex", "river.jpg", "Upper river", "Full story", "cover.jpg"]
        XCTAssertTrue(result.contains("<figcaption>"))
        let positions = try markers.map { try XCTUnwrap(result.range(of: $0)).lowerBound }
        XCTAssertEqual(positions, positions.sorted())
    }
    func testUnsafeFeedMarkupIsNotInserted() throws {
        let result = try ReaderContent.html(body: "<p>Article</p>", feed: "<script>alert(1)</script><img src='javascript:alert(1)'>", baseURL: base)
        XCTAssertFalse(result.contains("script"))
        XCTAssertFalse(result.contains("alert"))
    }
}

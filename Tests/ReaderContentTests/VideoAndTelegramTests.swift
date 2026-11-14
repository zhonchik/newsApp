import XCTest
import SwiftSoup
@testable import ReaderContent

final class VideoAndTelegramTests: XCTestCase {
    func testTelegramSelectsOneCopyButPreservesIntentionalRepetition() throws {
        let post = try SwiftSoup.parse("""
        <div class="tgme_widget_message_text"><b>Hello</b><br>Hello</div>
        <div class="tgme_widget_message_text"><b>Hello</b><br>Hello</div>
        """)
        let message = try TelegramContent.message(in: post)
        XCTAssertEqual(message.text, "Hello Hello")
        XCTAssertEqual(message.html.components(separatedBy: "<b>").count - 1, 1)
    }
    func testYouTubeURLFormsAndUntrustedHosts() {
        for url in ["https://youtu.be/abcdefghijk?t=3", "https://www.youtube.com/watch?v=abcdefghijk", "https://youtube.com/shorts/abcdefghijk", "https://www.youtube-nocookie.com/embed/abcdefghijk"] {
            XCTAssertEqual(VideoPreview.youtubeID(url), "abcdefghijk")
        }
        XCTAssertNil(VideoPreview.youtubeID("https://youtube.com.evil.test/watch?v=abcdefghijk"))
        XCTAssertNil(VideoPreview.youtubeID("https://youtube.com/watch?v=invalid"))
    }
    func testEmbedBecomesOneAllowlistedPlayerAcrossFeedAndBody() throws {
        let embed = "<iframe src='https://www.youtube.com/embed/abcdefghijk'></iframe>"
        let html = try ReaderContent.html(body: embed, feed: embed, baseURL: "https://example.com/story")
        XCTAssertTrue(html.contains("https://www.youtube-nocookie.com/embed/abcdefghijk"))
        XCTAssertEqual(html.components(separatedBy: "Open on YouTube").count - 1, 1)
        XCTAssertEqual(html.components(separatedBy: "<iframe").count - 1, 1)
    }
    func testInlineTelegramVideoAndPublisherSanitization() throws {
        let post = try SwiftSoup.parse("<video src='https://cdn.example.com/movie.mp4' poster='https://cdn.example.com/poster.jpg'></video>")
        let media = try VideoPreview.telegram(post, url: "https://t.me/channel/12")
        let html = try ReaderContent.html(body: media + "<script>alert(1)</script><iframe src='https://evil.example'></iframe><video autoplay onplay='alert(1)' src='javascript:evil'></video>", feed: "", baseURL: "https://t.me/channel/12")
        XCTAssertTrue(html.contains("<video"))
        XCTAssertTrue(html.contains("movie.mp4"))
        XCTAssertTrue(html.contains("controls"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("<iframe"))
        XCTAssertFalse(html.contains("javascript:"))
        XCTAssertFalse(html.contains("onplay"))
        XCTAssertFalse(html.contains("autoplay"))
    }
    func testMediaCacheURLsAndByteRanges() {
        let original = "https://cdn.example.com/movie.mp4?token=abc%2Fxyz"
        let cached = MediaRequest.cachedURL(original)!
        XCTAssertEqual(MediaRequest.remoteURL(URL(string: cached)!)?.absoluteString, original)
        XCTAssertNil(MediaRequest.cachedURL("file:///etc/passwd"))
        XCTAssertEqual(MediaRequest.range(nil, size: 100), 0..<100)
        XCTAssertEqual(MediaRequest.range("bytes=0-1", size: 100), 0..<2)
        XCTAssertEqual(MediaRequest.range("bytes=90-", size: 100), 90..<100)
        XCTAssertEqual(MediaRequest.range("bytes=-10", size: 100), 90..<100)
        XCTAssertEqual(MediaRequest.range("bytes=90-999", size: 100), 90..<100)
        XCTAssertNil(MediaRequest.range("bytes=100-", size: 100))
        XCTAssertNil(MediaRequest.range("bytes=4-2", size: 100))
        XCTAssertNil(MediaRequest.range("bytes=0-1,5-9", size: 100))
    }
    func testTelegramVideoPreviewAndMissingPoster() throws {
        let post = try SwiftSoup.parse("<video poster='https://cdn.example.com/poster.jpg'></video>")
        let card = try VideoPreview.telegram(post, url: "https://t.me/channel/12")
        let html = try ReaderContent.html(body: card, feed: card, baseURL: "https://t.me/channel/12")
        XCTAssertTrue(html.contains("poster.jpg"))
        XCTAssertTrue(html.contains("Watch video on Telegram"))
        let unsafe = try SwiftSoup.parse("<video poster='javascript:alert(1)'></video>")
        XCTAssertFalse(try VideoPreview.telegram(unsafe, url: "https://t.me/channel/12").contains("javascript:"))
        let noPoster = try SwiftSoup.parse("<div class='tgme_widget_message_video_player'></div>")
        XCTAssertTrue(try VideoPreview.telegram(noPoster, url: "https://t.me/channel/12").contains("Watch video"))
    }
}

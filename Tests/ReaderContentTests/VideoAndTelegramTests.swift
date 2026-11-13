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
    func testEmbedBecomesOneSafePreviewAcrossFeedAndBody() throws {
        let embed = "<iframe src='https://www.youtube.com/embed/abcdefghijk'></iframe>"
        let html = try ReaderContent.html(body: embed, feed: embed, baseURL: "https://example.com/story")
        XCTAssertTrue(html.contains("https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg"))
        XCTAssertEqual(html.components(separatedBy: "Watch on YouTube").count - 1, 1)
        XCTAssertFalse(html.contains("<iframe"))
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

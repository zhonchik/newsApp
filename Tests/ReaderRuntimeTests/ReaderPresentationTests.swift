import AppKit
import WebKit
import XCTest
import ReaderContent
@testable import ReaderRuntime

final class ReaderPresentationTests: XCTestCase {
    @MainActor func testLocalArticleReachesLayoutWhileImageRequestStalls() async throws {
        let cache = MediaCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let subscription = Subscription(name: "Example", address: "https://example.org/feed", kind: "rss")
        let item = RemoteArticle(id: "saved", title: "Saved article", url: "https://example.org/story", text: "", published: Date())
        let record = Article(item: item, subscription: subscription)
        record.key = "saved"
        let content = CachedArticle(text: "", html: "<p>Saved article text</p><img width='80' height='80' src='https://example.org/photo.jpg'>", feedHTML: "")
        let document = ReaderDocument(ArticleLink(record, hiddenText: ""), content: content)
        let input = ReaderPage.Input(article: document, hiddenText: "", palette: .saved(), version: 0)
        let page = await ReaderPage.prepare(input, cache: cache)
        let html = page.html
        XCTAssertEqual(page.input, input)
        XCTAssertTrue(html.contains(ReaderAppearance.stylesheet(input.palette)))
        XCTAssertTrue(html.contains("data-reader-src="))
        XCTAssertFalse(html.contains(" src=\"reader-media:"))
        let ready = expectation(description: "Article reached its presentation frame")
        let requested = expectation(description: "Deferred image requested")
        let observer = PageObserver(ready: ready, requested: requested)
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(observer, forURLScheme: "reader-media")
        config.userContentController.add(observer, contentWorld: .defaultClient, name: "readerReady")
        config.userContentController.addUserScript(WKUserScript(source: ReaderPresentation.afterFirstFrame,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        let start = ProcessInfo.processInfo.systemUptime
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let view = WKWebView(frame: window.contentLayoutRect, configuration: config)
        window.contentView = view
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        view.loadHTMLString(html, baseURL: nil)
        await fulfillment(of: [ready, requested], timeout: 30)
        let text = try await view.evaluateJavaScript("document.querySelector('article').innerText")
        XCTAssertEqual((text as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), "Saved article text")
        if let frame = observer.readyTime {
            print("Reader test: WebKit creation to article frame with stalled image = \(Int((frame - start) * 1000)) ms")
        }
    }
}

@MainActor private final class PageObserver: NSObject, WKScriptMessageHandler, WKURLSchemeHandler {
    let ready: XCTestExpectation
    let requested: XCTestExpectation
    var readyTime: TimeInterval?
    init(ready: XCTestExpectation, requested: XCTestExpectation) {
        self.ready = ready
        self.requested = requested
    }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        XCTAssertEqual(message.body as? String, "saved")
        readyTime = ProcessInfo.processInfo.systemUptime
        ready.fulfill()
    }
    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        // Deliberately leave the image pending throughout the assertion.
        requested.fulfill()
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

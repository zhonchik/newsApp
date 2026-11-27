import AppKit
import CryptoKit
import SwiftUI
import WebKit
import XCTest
import ReaderContent
@testable import ReaderRuntime

final class NativeLayoutTests: XCTestCase {
    func testBodyWeightAcrossThemesAndContrastSettings() {
        XCTAssertEqual(ReaderAppearance.bodyWeight(dark: false, increasedContrast: false), 400)
        XCTAssertEqual(ReaderAppearance.bodyWeight(dark: false, increasedContrast: true), 400)
        XCTAssertEqual(ReaderAppearance.bodyWeight(dark: true, increasedContrast: false), 350)
        XCTAssertEqual(ReaderAppearance.bodyWeight(dark: true, increasedContrast: true), 400)
    }

    @MainActor func testNativeReaderRestoresSavedScrollOffset() async throws {
        let html = (0..<80).map { "<p>Paragraph \($0). A long article keeps its reading position when reopened.</p>" }.joined()
        let document = ReaderDocument(url: URL(string: "https://publisher.example/story")!, title: "Long article", html: html)
        let page = await ReaderPage.prepare(.init(article: document, hiddenText: "", palette: .saved(), version: 0))
        let body = try XCTUnwrap(page.displayBody)
        let host = NSHostingView(rootView: NativeArticleView(content: body, article: document, palette: .saved(),
            onDisplay: {}, reload: {}, move: { _ in }, displayText: page.displayText, initialOffset: 420))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = host; window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func findScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView { return scroll }
            return view.subviews.compactMap(findScroll).first
        }
        var restored = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(100))
            host.layoutSubtreeIfNeeded()
            if let scroll = findScroll(host), abs(scroll.contentView.bounds.minY - 420) < 1 {
                restored = true; break
            }
        }
        XCTAssertTrue(restored, "The native scroll view must restore the saved point offset")
    }

    @MainActor func testCachedPhotosAppearInNativeRSSAndTelegramLayouts() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let imageURL = "https://example.org/photo.png"
        let file = root.appendingPathComponent(SHA256.hash(data: Data(imageURL.utf8)).map { String(format: "%02x", $0) }.joined())
        let img = NSImage(size: NSSize(width: 80, height: 32), flipped: false) { bounds in
            NSColor.green.setFill(); bounds.fill()
            return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(img.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: file)
        try JSONEncoder().encode(MediaCache.Entry(file: file, mime: "image/png", size: data.count)).write(to: file.appendingPathExtension("json"))
        let cache = MediaCache(directory: root)

        for url in ["https://t.me/example/42", "https://example.org/rss/story"] {
            let subscription = Subscription(name: "Example", address: url, kind: url.contains("t.me") ? "telegram" : "rss")
            let item = RemoteArticle(id: "story", title: "A saved story", url: url, text: "", published: Date())
            let link = ArticleLink(Article(item: item, subscription: subscription), hiddenText: "")
            let html = "<p>Read the <a href='https://example.org/source'>original report</a>.</p><figure><img src='\(imageURL)' alt='Test photo'><figcaption>Photo caption</figcaption></figure>"
            let doc = ReaderDocument(link, content: CachedArticle(text: "", html: html, feedHTML: html))
            let input = ReaderPage.Input(article: doc, hiddenText: "", palette: .saved(), version: 0)
            let page = await ReaderPage.prepare(input, cache: cache)
            let laidOut = expectation(description: "Native article laid out")
            laidOut.assertForOverFulfill = false
            let view = NativeArticleView(content: try XCTUnwrap(page.displayBody), article: doc, palette: input.palette,
                                         onDisplay: { laidOut.fulfill() }, reload: {}, move: { _ in }, displayText: page.displayText, imageRatios: page.imageRatios, cache: cache)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFrontRegardless()
            defer { window.orderOut(nil) }
            await fulfillment(of: [laidOut], timeout: 10)
            var foundPhoto = false
            for _ in 0..<30 {
                try await Task.sleep(for: .milliseconds(100))
                host.layoutSubtreeIfNeeded()
                guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                host.cacheDisplay(in: host.bounds, to: rep)
                let x = rep.pixelsWide / 2
                foundPhoto = stride(from: 0, to: rep.pixelsHigh, by: 8).contains { y in
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return c.greenComponent > 0.75 && c.redComponent < 0.25 && c.blueComponent < 0.25
                }
                if foundPhoto { break }
            }
            XCTAssertTrue(foundPhoto, "Cached photo must be visible in the article")
            func containsWebView(_ v: NSView) -> Bool { v is WKWebView || v.subviews.contains(where: containsWebView) }
            XCTAssertFalse(containsWebView(host))
        }
    }
}

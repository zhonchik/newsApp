import SwiftUI
import WebKit
import SwiftSoup

/// A single scrolling reader document. Publisher scripts and embeds cannot execute.
struct ArticleWebView {
    let article: Article
    let hiddenText: String
    let move: (Int) -> Void

    private func document() -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let fallback = "<p>" + escape(article.text).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        let body = (try? ReaderContent.html(body: article.html.isEmpty ? fallback : article.html, feed: article.feedHTML, baseURL: article.url, hiddenText: hiddenText)) ?? fallback
        let headline = ContentRules.isTelegram(article.url) ? "" : "<h1>\(escape(article.title))</h1>"
        return """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data:; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: light dark; font: -apple-system-body; }
        body { margin:0 auto; padding:24px; max-width:680px; overflow-wrap:anywhere; }
        article { font-family: Georgia, serif; font-size:1.15em; line-height:1.7; }
        h1 { font-family: Georgia, serif; font-size:2em; line-height:1.2; }
        h2,h3,h4 { line-height:1.3; } img { max-width:100%; height:auto; border-radius:6px; }
        figure { margin:1.5em 0; } figcaption,header,footer { font: -apple-system-caption1; color: GrayText; }
        a { color: #298c81; } blockquote { border-left:3px solid #298c81; margin:1em 0; padding-left:1em; }
        pre { overflow-x:auto; padding:12px; background:light-dark(#f3f3f3,#252525); } table { display:block; overflow-x:auto; border-collapse:collapse; }
        td,th { border:1px solid GrayText; padding:8px; } footer { margin-top:32px; }
        </style></head><body><header>\(escape(article.source)) · \(escape(article.published.formatted(date: .abbreviated, time: .omitted)))</header>
        \(headline)<article>\(body)</article>
        <footer><a href="\(escape(article.url))">Read original</a></footer></body></html>
        """
    }
    func makeCoordinator() -> Coordinator { Coordinator(move: move) }
    func makeWebView(_ coordinator: Coordinator) -> ReaderWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = ReaderWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.move = move
        #if os(iOS)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let gesture = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.swipe(_:)))
            gesture.direction = direction; gesture.delegate = coordinator; webView.addGestureRecognizer(gesture)
        }
        #endif
        return webView
    }
    func update(_ webView: ReaderWebView, coordinator: Coordinator) {
        coordinator.move = move; webView.move = move
        let html = document()
        guard coordinator.document != html else { return }
        coordinator.document = html
        webView.loadHTMLString(html, baseURL: URL(string: article.url))
    }
    class Coordinator: NSObject, WKNavigationDelegate {
        var move: (Int) -> Void
        var document = ""
        init(move: @escaping (Int) -> Void) { self.move = move }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard action.navigationType == .linkActivated else { decisionHandler(.allow); return }
            if let url = action.request.url, ["https", "http"].contains(url.scheme ?? "") {
                #if os(iOS)
                UIApplication.shared.open(url)
                #else
                NSWorkspace.shared.open(url)
                #endif
            }
            decisionHandler(.cancel)
        }
        #if os(iOS)
        @objc func swipe(_ gesture: UISwipeGestureRecognizer) { move(gesture.direction == .left ? 1 : -1) }
        #endif
    }
}

final class ReaderWebView: WKWebView {
    var move: ((Int) -> Void)?
    #if os(macOS)
    override func swipe(with event: NSEvent) {
        if event.deltaX != 0 { move?(event.deltaX < 0 ? 1 : -1) }
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 124 { move?(1) }
        else if event.keyCode == 123 { move?(-1) }
        else { super.keyDown(with: event) }
    }
    #endif
}
#if os(iOS)
extension ArticleWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> ReaderWebView { makeWebView(context.coordinator) }
    func updateUIView(_ view: ReaderWebView, context: Context) { update(view, coordinator: context.coordinator) }
}
extension ArticleWebView.Coordinator: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
}
#else
extension ArticleWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> ReaderWebView { makeWebView(context.coordinator) }
    func updateNSView(_ view: ReaderWebView, context: Context) { update(view, coordinator: context.coordinator) }
}
#endif

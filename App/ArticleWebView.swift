import SwiftUI
import WebKit
import SwiftSoup

/// A persistent reader document. Only generated YouTube embeds may run provider scripts.
struct ArticleWebView {
    @Environment(\.colorScheme) private var colorScheme
    let article: ReaderDocument
    let hiddenText: String
    let renderVersion: Int
    let onDisplay: () -> Void
    let onFailure: (String) -> Void
    let reload: () async -> Void
    let move: (Int) -> Void

    @AppStorage("lightText") private var lightText = "#202020"
    @AppStorage("lightBackground") private var lightBackground = "#FFFFFF"
    @AppStorage("darkText") private var darkText = "#EEEEEE"
    @AppStorage("darkBackground") private var darkBackground = "#181818"

    nonisolated private static func document(article: ReaderDocument, hiddenText: String, palette: ReaderPalette) async -> String {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let fallback = "<p>" + escape(article.text).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        let body = (try? ReaderContent.html(body: article.html.isEmpty ? fallback : article.html, feed: article.feedHTML, baseURL: article.url, hiddenText: hiddenText)) ?? fallback
        let headline = ContentRules.isTelegram(article.url) ? "" : "<h1>\(escape(article.title))</h1>"
        let html = """
        <!doctype html><html data-reader-key="\(escape(article.key))"><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data: reader-media:; media-src https: reader-media:; frame-src https://www.youtube-nocookie.com; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: light dark; font: -apple-system-body; }
        body { color: \(ReaderPalette.valid(palette.lightText, fallback: "#202020")); background: \(ReaderPalette.valid(palette.lightBackground, fallback: "#FFFFFF")); }
        @media (prefers-color-scheme: dark) { body { color: \(ReaderPalette.valid(palette.darkText, fallback: "#EEEEEE")); background: \(ReaderPalette.valid(palette.darkBackground, fallback: "#181818")); } }
        body { margin:0 auto; padding:0 24px 24px; max-width:680px; overflow-wrap:anywhere; }
        article { font-family: Georgia, serif; font-size:1.15em; line-height:1.7; }
        h1 { font-family: Georgia, serif; font-size:1.4em; line-height:1.3; }
        h2,h3,h4 { line-height:1.3; } img { max-width:100%; height:auto; border-radius:6px; }
        video, iframe { display:block; width:100%; height:auto; aspect-ratio:16/9; border:0; background:#181818; object-fit:contain; }
        img:not([width][height]) { width:100%; height:auto; aspect-ratio:16/9; object-fit:contain; }
        figure img { width:100%; }
        figure { margin:1.5em 0; } figcaption,header,footer { font: -apple-system-caption1; color: GrayText; }
        a { color: #298c81; } blockquote { border-left:3px solid #298c81; margin:1em 0; padding-left:1em; }
        pre { overflow-x:auto; padding:12px; background:light-dark(#f3f3f3,#252525); } table { display:block; overflow-x:auto; border-collapse:collapse; }
        td,th { border:1px solid GrayText; padding:8px; } footer { margin-top:32px; }
        </style></head><body><header>\(escape(article.source)) · \(escape(article.published.formatted(date: .abbreviated, time: .omitted)))</header>
        \(headline)<article>\(body)</article>
        <footer><a href="\(escape(article.url))">Read original</a></footer></body></html>
        """
        return (try? await MediaCache.shared.rewrite(html)) ?? html
    }
    @MainActor func makeCoordinator() -> Coordinator { Coordinator(move: move, reload: reload, onDisplay: onDisplay, onFailure: onFailure) }
    @MainActor func makeWebView(_ coordinator: Coordinator) -> ReaderWebView {
        let config = WKWebViewConfiguration()
        // The parent CSP blocks scripts; only the allowlisted YouTube frame runs JS.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()
        config.setURLSchemeHandler(MediaSchemeHandler(), forURLScheme: "reader-media")
        // Isolated app script: publisher scripts remain blocked by the document CSP.
        let playbackScript = """
        requestAnimationFrame(function() { requestAnimationFrame(function() {
          window.webkit.messageHandlers.readerReady.postMessage(document.documentElement.getAttribute('data-reader-key') || '');
        }); });
        document.addEventListener('play', function(event) {
          if (event.target.tagName === 'VIDEO') {
            window.webkit.messageHandlers.cacheVideo.postMessage(event.target.currentSrc || event.target.src);
          }
        }, true);
        let pull = 0, lastWheel = 0;
        document.addEventListener('wheel', function(event) {
          if (Date.now() - lastWheel > 400) pull = 0;
          lastWheel = Date.now();
          if (window.scrollY <= 0 && event.deltaY < 0) {
            pull -= event.deltaY;
            if (pull > 160) { pull = 0; window.webkit.messageHandlers.readerRefresh.postMessage('refresh'); }
          } else { pull = 0; }
        }, {passive:true});
        """
        config.userContentController.addUserScript(WKUserScript(source: playbackScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
        config.userContentController.add(coordinator, contentWorld: .defaultClient, name: "cacheVideo")
        config.userContentController.add(coordinator, contentWorld: .defaultClient, name: "readerRefresh")
        config.userContentController.add(coordinator, contentWorld: .defaultClient, name: "readerReady")
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = .all
        #endif
        let webView = ReaderWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        applyBackground(webView)
        webView.move = move
        #if os(iOS)
        webView.scrollView.alwaysBounceVertical = true
        let refresh = UIRefreshControl()
        refresh.addTarget(coordinator, action: #selector(Coordinator.pullToRefresh(_:)), for: .valueChanged)
        webView.scrollView.refreshControl = refresh
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero
        webView.scrollView.scrollIndicatorInsets = .zero
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let gesture = UISwipeGestureRecognizer(target: coordinator, action: #selector(Coordinator.swipe(_:)))
            gesture.direction = direction; gesture.delegate = coordinator; webView.addGestureRecognizer(gesture)
        }
        #endif
        return webView
    }
    @MainActor func update(_ webView: ReaderWebView, coordinator: Coordinator) {
        coordinator.move = move; coordinator.reload = reload; coordinator.onDisplay = onDisplay; coordinator.onFailure = onFailure; webView.move = move
        applyBackground(webView)
        let palette = ReaderPalette(lightText: lightText, lightBackground: lightBackground, darkText: darkText, darkBackground: darkBackground)
        let input = RenderInput(article: article, hiddenText: hiddenText, palette: palette, version: renderVersion)
        guard coordinator.input != input else { return }
        coordinator.input = input
        coordinator.renderTask?.cancel()
        webView.beginLoading()
        coordinator.renderTask = Task { @MainActor [weak webView, weak coordinator] in
            let html = await Task.detached(priority: .userInitiated) {
                await Self.document(article: input.article, hiddenText: input.hiddenText, palette: input.palette)
            }.value
            guard !Task.isCancelled, let coordinator, coordinator.input == input else { return }
            // A stable HTTPS base supplies the Referer required by YouTube embeds.
            coordinator.lastHTML = html; coordinator.recoveries = 0
            if let webView { coordinator.load(html, in: webView) }
        }
    }
    @MainActor private func applyBackground(_ webView: ReaderWebView) {
        let hex = ReaderPalette.valid(colorScheme == .dark ? darkBackground : lightBackground, fallback: colorScheme == .dark ? "#181818" : "#FFFFFF")
        let rgb = UInt32(hex.dropFirst(), radix: 16) ?? 0
        #if os(iOS)
        let color = UIColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        webView.isOpaque = false
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
        webView.underPageBackgroundColor = color
        #else
        webView.underPageBackgroundColor = NSColor(red: CGFloat((rgb >> 16) & 255) / 255, green: CGFloat((rgb >> 8) & 255) / 255, blue: CGFloat(rgb & 255) / 255, alpha: 1)
        #endif
    }
    struct RenderInput: Equatable, Sendable {
        let article: ReaderDocument
        let hiddenText: String
        let palette: ReaderPalette
        let version: Int
    }
    @MainActor class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var move: (Int) -> Void
        var reload: () async -> Void
        var onDisplay: () -> Void
        var onFailure: (String) -> Void
        var lastHTML = ""
        var recoveries = 0
        private var refreshing = false
        private var loadTimeout: Task<Void, Never>?
        private var activeNavigation: WKNavigation?
        var input: RenderInput?
        var renderTask: Task<Void, Never>?
        deinit { renderTask?.cancel(); loadTimeout?.cancel() }
        init(move: @escaping (Int) -> Void, reload: @escaping () async -> Void, onDisplay: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.move = move; self.reload = reload; self.onDisplay = onDisplay; self.onFailure = onFailure
        }
        func load(_ html: String, in webView: ReaderWebView) {
            activeNavigation = webView.loadHTMLString(html, baseURL: URL(string: "https://com.currentreader.current/"))
            loadTimeout?.cancel()
            loadTimeout = Task { @MainActor [weak self, weak webView] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, let webView else { return }
                self.recover(webView)
            }
        }
        // A navigation commit is too early: keep Preparing visible until the
        // page's animation-frame callback confirms it has reached rendering.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === activeNavigation else { return }
            // Animation-frame callbacks can be throttled while the loading overlay
            // covers WebKit. Confirm usable DOM/layout as a second readiness path.
            webView.evaluateJavaScript("document.readyState === 'complete' && !!document.body && document.body.getBoundingClientRect().height > 0", in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, navigation === self.activeNavigation else { return }
                if case .success(let value) = result, value as? Bool == true {
                    self.loadTimeout?.cancel()
                    (webView as? ReaderWebView)?.endLoading()
                    self.onDisplay()
                }
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { recover(webView) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            if navigation === activeNavigation, (error as NSError).code != NSURLErrorCancelled { recover(webView) }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            if navigation === activeNavigation, (error as NSError).code != NSURLErrorCancelled { recover(webView) }
        }
        private func recover(_ view: WKWebView) {
            guard let view = view as? ReaderWebView else { return }
            loadTimeout?.cancel()
            if recoveries == 0, !lastHTML.isEmpty {
                recoveries += 1
                load(lastHTML, in: view)
            } else {
                view.endLoading()
                onFailure("The article could not be displayed. Please try again.")
                // An actionable error instead of an indefinitely blank reader.
                view.loadHTMLString("<html><meta name='color-scheme' content='light dark'><body><p>The reader could not display this article. Pull down to reload it, or switch articles and try again.</p></body></html>", baseURL: nil)
            }
        }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame else { return }
            if message.name == "readerReady", let key = message.body as? String, key == input?.article.key {
                loadTimeout?.cancel()
                (message.webView as? ReaderWebView)?.endLoading()
                onDisplay()
            } else if message.name == "cacheVideo", let raw = message.body as? String, let url = URL(string: raw), url.scheme == "https" {
                Task { _ = try? await MediaCache.shared.entry(for: url) }
            } else if message.name == "readerRefresh" { Task { await refresh() } }
        }
        private func refresh() async {
            guard !refreshing else { return }
            refreshing = true
            await reload()
            refreshing = false
        }
        #if os(iOS)
        @objc func pullToRefresh(_ control: UIRefreshControl) {
            Task { await refresh(); control.endRefreshing() }
        }
        #endif
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Allow provider navigation inside the embedded player only.
            if action.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
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
    #if os(iOS)
    private let spinner = UIActivityIndicatorView(style: .medium)
    func beginLoading() {
        if spinner.superview == nil {
            addSubview(spinner); spinner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        spinner.startAnimating()
    }
    func endLoading() { spinner.stopAnimating() }
    #else
    private let spinner = NSProgressIndicator()
    func beginLoading() {
        if spinner.superview == nil {
            spinner.style = .spinning; spinner.isDisplayedWhenStopped = false
            addSubview(spinner); spinner.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor)])
        }
        spinner.startAnimation(nil)
    }
    func endLoading() { spinner.stopAnimation(nil) }
    #endif
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

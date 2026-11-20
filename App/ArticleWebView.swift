import SwiftUI
import WebKit

/// A persistent reader document. Only generated YouTube embeds may run provider scripts.
struct ArticleWebView {
    @Environment(\.colorScheme) private var colorScheme
    let launchPage: ReaderPage?
    let article: ReaderDocument?
    let hiddenText: String
    let renderVersion: Int
    let onDisplay: () -> Void
    let onFailure: (String) -> Void
    let reload: () async -> Void
    let move: (Int) -> Void

    @AppStorage("lightText") private var lightText = "#202020"
    @AppStorage("lightBackground") private var lightBackground = "#FFFFFF"
    @AppStorage("darkText") private var darkText = "#DEDCD8"
    @AppStorage("darkBackground") private var darkBackground = "#181818"

    @MainActor func makeCoordinator() -> Coordinator { Coordinator(move: move, reload: reload, onDisplay: onDisplay, onFailure: onFailure) }
    @MainActor func makeWebView(_ coordinator: Coordinator) -> ReaderWebView {
        LaunchMetrics.mark("Reader WebKit creation started")
        let config = WKWebViewConfiguration()
        // The parent CSP blocks scripts; only the allowlisted YouTube frame runs JS.
        config.defaultWebpagePreferences.allowsContentJavaScript = true
        config.websiteDataStore = .default()
        config.setURLSchemeHandler(MediaSchemeHandler(), forURLScheme: "reader-media")
        // Isolated app script: publisher scripts remain blocked by the document CSP.
        let playbackScript = """
        \(ReaderPresentation.afterFirstFrame)
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
        LaunchMetrics.mark("Reader WebKit created")
        return webView
    }
    @MainActor func update(_ webView: ReaderWebView, coordinator: Coordinator) {
        coordinator.move = move; coordinator.reload = reload; coordinator.onDisplay = onDisplay; coordinator.onFailure = onFailure; webView.move = move
        applyBackground(webView)
        guard let article else { return }
        let palette = ReaderPalette(lightText: lightText, lightBackground: lightBackground, darkText: darkText, darkBackground: darkBackground)
        let input = ReaderPage.Input(article: article, hiddenText: hiddenText, palette: palette, version: renderVersion)
        guard coordinator.input != input else { return }
        coordinator.input = input
        coordinator.renderTask?.cancel()
        webView.beginLoading()
        if let launchPage, launchPage.input == input {
            coordinator.show(launchPage, in: webView)
            return
        }
        coordinator.renderTask = Task { @MainActor [weak webView, weak coordinator] in
            let page = await ReaderPage.prepare(input)
            guard !Task.isCancelled, let webView, let coordinator, coordinator.input == input else { return }
            coordinator.show(page, in: webView)
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
        var input: ReaderPage.Input?
        var renderTask: Task<Void, Never>?
        deinit { renderTask?.cancel(); loadTimeout?.cancel() }
        init(move: @escaping (Int) -> Void, reload: @escaping () async -> Void, onDisplay: @escaping () -> Void, onFailure: @escaping (String) -> Void) {
            self.move = move; self.reload = reload; self.onDisplay = onDisplay; self.onFailure = onFailure
        }
        func show(_ page: ReaderPage, in webView: ReaderWebView) {
            lastHTML = page.html
            recoveries = 0
            load(page.html, in: webView)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            guard navigation === activeNavigation else { return }
            LaunchMetrics.mark("Article provisional navigation started")
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            guard navigation === activeNavigation else { return }
            LaunchMetrics.mark("Article navigation committed")
        }
        func load(_ html: String, in webView: ReaderWebView) {
            LaunchMetrics.mark("Article navigation started")
            activeNavigation = webView.loadHTMLString(html, baseURL: URL(string: "https://com.currentreader.current/"))
            LaunchMetrics.mark("Article navigation submitted")
            loadTimeout?.cancel()
            loadTimeout = Task { @MainActor [weak self, weak webView] in
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
                guard let self, let webView else { return }
                LaunchMetrics.mark("15-second WebKit recovery timer fired")
                self.recover(webView)
            }
        }
        // Confirm actual layout before recording the first readable article.
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard navigation === activeNavigation else { return }
            // Confirm usable layout if WebKit throttles animation-frame callbacks.
            webView.evaluateJavaScript("document.readyState === 'complete' && !!document.body && document.body.getBoundingClientRect().height > 0", in: nil, in: .defaultClient) { [weak self, weak webView] result in
                guard let self, navigation === self.activeNavigation else { return }
                if case .success(let value) = result, value as? Bool == true {
                    self.loadTimeout?.cancel()
                    (webView as? ReaderWebView)?.endLoading()
                    self.onDisplay()
                }
            }
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { if activeNavigation != nil { recover(webView) } }
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

import SwiftUI
import AVKit
import ImageIO
import WebKit

struct HybridArticleReader: View {
    let launchPage: ReaderPage?
    let article: ReaderDocument?
    let hiddenText: String
    let renderVersion: Int
    let onDisplay: (String) -> Void
    let onFailure: (String) -> Void
    let reload: () async -> Void
    let move: (Int) -> Void

    @AppStorage("lightText") private var lightText = "#202020"
    @AppStorage("lightBackground") private var lightBackground = "#FFFFFF"
    @AppStorage("darkText") private var darkText = "#DEDCD8"
    @AppStorage("darkBackground") private var darkBackground = "#181818"
    @Environment(\.colorScheme) private var scheme
    @State private var prepared: ReaderPage?

    private var input: ReaderPage.Input? {
        article.map { ReaderPage.Input(article: $0, hiddenText: hiddenText,
            palette: ReaderPalette(lightText: lightText, lightBackground: lightBackground, darkText: darkText, darkBackground: darkBackground),
            version: renderVersion) }
    }
    var body: some View {
        Group {
            if let input, let page = [launchPage, prepared].compactMap({ $0 }).first(where: { $0.input == input }) {
                if let native = page.nativeBody {
                    nativeView(native, article: input.article)
                        .id(input.article.key)
                } else {
                    ArticleWebView(launchPage: page, article: input.article, hiddenText: hiddenText,
                        renderVersion: renderVersion, onDisplay: { onDisplay("WebKit") },
                        onFailure: onFailure, reload: reload, move: move)
                }
            } else { ProgressView().accessibilityLabel("Opening article") }
        }
        .task(id: input) {
            guard let input, launchPage?.input != input, prepared?.input != input else { return }
            let page = await ReaderPage.prepare(input)
            if !Task.isCancelled { prepared = page }
        }
    }

    private func color(_ value: String, fallback: String) -> Color {
        let rgb = UInt32(ReaderPalette.valid(value, fallback: fallback).dropFirst(), radix: 16) ?? 0
        return Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    private func nativeView(_ body: NativeArticleBody, article: ReaderDocument) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                Text("\(article.source) · \(article.published.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
                if !ContentRules.isTelegram(article.url) {
                    Text(article.title).font(.system(.title2, design: .serif).bold()).accessibilityAddTraits(.isHeader)
                }
                ForEach(body.blocks.indices, id: \.self) { index in
                    block(body.blocks[index])
                }
                if let url = URL(string: article.url) { Link("Read original", destination: url) }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background { GeometryReader { _ in Color.clear.onAppear { onDisplay("Native") } } }
        }
        .foregroundStyle(color(scheme == .dark ? darkText : lightText, fallback: scheme == .dark ? "#DEDCD8" : "#202020"))
        .background(color(scheme == .dark ? darkBackground : lightBackground, fallback: scheme == .dark ? "#181818" : "#FFFFFF"))
        .refreshable { await reload() }
        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in
            let delta = value.translation
            if abs(delta.width) > max(70, abs(delta.height) * 2) { move(delta.width < 0 ? 1 : -1) }
        })
        #if os(macOS)
        .focusable()
        .onMoveCommand { direction in
            if direction == .left { move(-1) }
            if direction == .right { move(1) }
        }
        .contextMenu { Button("Reload article") { Task { await reload() } } }
        #endif
    }

    @ViewBuilder private func block(_ block: NativeArticleBody.Block) -> some View {
        switch block {
        case .text(let style, let runs):
            let font: Font = switch style {
            case .heading: .system(.title2, design: .serif).bold()
            case .subheading: .system(.headline, design: .serif)
            case .caption: .caption
            default: .system(.title3, design: .serif)
            }
            Text(attributed(runs)).font(font).textSelection(.enabled).lineSpacing(5)
                .padding(.leading, style == .quote ? 12 : 0)
                .overlay(alignment: .leading) { if style == .quote { Rectangle().fill(.tint).frame(width: 3) } }
                .accessibilityAddTraits(style == .heading || style == .subheading ? .isHeader : [])
        case .image(let url, let alt, let link, let original):
            if let link {
                Link(destination: link) { ArticlePhoto(url: url, alt: alt, originalSize: original) }
            } else { ArticlePhoto(url: url, alt: alt, originalSize: original) }
        case .video(let url, let poster):
            ArticleVideo(url: url, poster: poster).id(url)
        case .youtube(let id):
            YouTubeBlock(id: id).id(id)
        }
    }

    private func attributed(_ runs: [NativeArticleBody.Run]) -> AttributedString {
        var result = AttributedString()
        for run in runs {
            var span = AttributedString(run.text)
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            span.inlinePresentationIntent = intent
            span.link = run.link
            result.append(span)
        }
        return result
    }
}

private struct ArticlePhoto: View {
    let url: URL
    let alt: String
    var originalSize = false
    @State private var bitmap: CGImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let bitmap {
                Image(decorative: bitmap, scale: 1).resizable().scaledToFit()
                    .frame(maxWidth: originalSize ? CGFloat(bitmap.width) : .infinity)
            } else if failed {
                Link(alt.isEmpty ? "Open image" : alt, destination: url)
            } else { ProgressView().frame(maxWidth: .infinity, minHeight: 80) }
        }
        .accessibilityLabel(alt.isEmpty ? "Article image" : alt)
        .task(id: url) {
            bitmap = nil; failed = false
            do {
                let entry = try await MediaCache.shared.entry(for: url)
                let image = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(entry.file as CFURL, nil) else { return nil as CGImage? }
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048]
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
                }.value
                guard !Task.isCancelled else { return }
                bitmap = image; failed = image == nil
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

private struct ArticleVideo: View {
    let url: URL
    let poster: URL?
    @State private var player: AVPlayer?
    @State private var playing = false
    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) }
            else {
                Button { playing = true } label: {
                    ZStack {
                        Color.black
                        if let poster { ArticlePhoto(url: poster, alt: "Video poster") }
                        Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white)
                    }
                }.buttonStyle(.plain).accessibilityLabel("Play video")
            }
        }.aspectRatio(16/9, contentMode: .fit)
        .task(id: playing) {
            guard playing else { return }
            let local = await MediaCache.shared.cachedFile(for: url)
            guard !Task.isCancelled else { return }
            let video = AVPlayer(url: local ?? url)
            player = video; video.play()
            if local == nil { _ = try? await MediaCache.shared.entry(for: url) }
        }
        .onDisappear { player?.pause() }
    }
}

private struct YouTubeBlock: View {
    let id: String
    @State private var showing = false
    var body: some View {
        Group {
            if showing { EmbeddedYouTube(id: id) }
            else { Button("Play YouTube video", systemImage: "play.rectangle.fill") { showing = true } }
        }.frame(maxWidth: .infinity).aspectRatio(16/9, contentMode: .fit)
    }
}

private struct EmbeddedYouTube {
    let id: String
    func makePlayer() -> WKWebView {
        let config = WKWebViewConfiguration()
        #if os(iOS)
        config.allowsInlineMediaPlayback = true
        #endif
        let view = WKWebView(frame: .zero, configuration: config)
        // id was validated by VideoPreview.youtubeID during parsing.
        let html = """
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; frame-src https://www.youtube-nocookie.com">
        <style>*{margin:0}iframe{width:100vw;height:100vh;border:0}</style>
        <iframe src="https://www.youtube-nocookie.com/embed/\(id)?playsinline=1" referrerpolicy="strict-origin-when-cross-origin" allow="encrypted-media; fullscreen; picture-in-picture" allowfullscreen></iframe>
        """
        view.loadHTMLString(html, baseURL: URL(string: "https://com.currentreader.current/"))
        return view
    }
}
#if os(iOS)
extension EmbeddedYouTube: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makePlayer() }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#else
extension EmbeddedYouTube: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makePlayer() }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#endif

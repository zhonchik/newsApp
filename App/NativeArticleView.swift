#if SWIFT_PACKAGE
import ReaderContent
#endif
import SwiftUI
import AVKit
import ImageIO
import WebKit

struct NativeArticleView: View {
    let content: NativeArticleBody
    let article: ReaderDocument
    let palette: ReaderPalette
    let onDisplay: () -> Void
    let reload: () async -> Void
    let move: (Int) -> Void
    var displayTitle: String? = nil
    let displayText: [Int: AttributedString]
    var imageRatios: [URL: Double] = [:]
    var initialOffset: Double = 0
    var onScroll: (Double) -> Void = { _ in }
    var openLink: (URL) -> Void = { _ in }
    var cache = MediaCache.shared
    @Environment(\.colorScheme) private var scheme

    @Environment(\.colorSchemeContrast) private var contrast
    #if os(iOS)
    private typealias PlatformFont = UIFont
    @ScaledMetric(relativeTo: .body) private var bodySize = UIFont.preferredFont(
        forTextStyle: .body, compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
    ).pointSize
    #else
    private typealias PlatformFont = NSFont
    private var bodySize: CGFloat { NSFont.preferredFont(forTextStyle: .body, options: [:]).pointSize }
    #endif

    private var bodyTypeface: PlatformFont {
        let size = bodySize * ReaderAppearance.bodyScale
        let weight = ReaderAppearance.bodyWeight(dark: scheme == .dark, increasedContrast: contrast == .increased)
        // CSS 350 lies halfway between Apple's light (300) and regular (400).
        let fraction = CGFloat(400 - weight) / 100
        let system = PlatformFont.systemFont(ofSize: size, weight: .init(rawValue: PlatformFont.Weight.light.rawValue * fraction))
        guard let serif = system.fontDescriptor.withDesign(.serif) else { return system }
        #if os(iOS)
        return UIFont(descriptor: serif, size: size)
        #else
        return NSFont(descriptor: serif, size: size) ?? system
        #endif
    }

    private var ink: Color {
        color(scheme == .dark ? palette.darkText : palette.lightText, fallback: scheme == .dark ? "#DEDCD8" : "#202020")
    }

    private func color(_ value: String, fallback: String) -> Color {
        let rgb = UInt32(ReaderPalette.valid(value, fallback: fallback).dropFirst(), radix: 16) ?? 0
        return Color(red: Double(rgb >> 16) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    var body: some View {
        let typeface = bodyTypeface
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(article.source) · \(article.published.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                if !ContentRules.isTelegram(article.url) {
                    Text(displayTitle ?? article.title).font(.system(.title2, design: .serif).bold()).accessibilityAddTraits(.isHeader)
                }
                ForEach(content.blocks.indices, id: \.self) { index in
                    block(content.blocks[index], index: index, typeface: typeface)
                }
                if let url = URL(string: article.url) { Link(destination: url) { Text("Original article").underline() }
                    .environment(\.openURL, OpenURLAction { .systemAction($0) }) }
            }
            .frame(maxWidth: 680, alignment: .leading)
            .padding(.horizontal, 24).padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background(ReaderScrollView(initialOffset: initialOffset, onScroll: onScroll))
            .background { GeometryReader { _ in Color.clear.onAppear { onDisplay() } } }
        }
        .environment(\.openURL, OpenURLAction { url in openLink(url); return .handled })
        .foregroundStyle(ink)
        .tint(ink)
        .background(color(scheme == .dark ? palette.darkBackground : palette.lightBackground, fallback: scheme == .dark ? "#181818" : "#FFFFFF"))
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

    @ViewBuilder private func block(_ block: NativeArticleBody.Block, index: Int, typeface: PlatformFont) -> some View {
        switch block {
        case .text(let style, _):
            let font: Font = switch style {
            case .heading: .system(.title2, design: .serif).bold()
            case .subheading: .system(.headline, design: .serif)
            case .caption: .caption
            case .paragraph, .quote: Font(typeface)
            }
            let naturalHeight = typeface.ascender - typeface.descender + typeface.leading
            let spacing = max(0, typeface.pointSize * ReaderAppearance.lineHeight - naturalHeight)
            Text(displayText[index] ?? AttributedString()).font(font).textSelection(.enabled)
                .lineSpacing(style == .paragraph || style == .quote ? spacing : 5)
                .padding(.leading, style == .quote ? 12 : 0)
                .overlay(alignment: .leading) { if style == .quote { Rectangle().fill(.tint).frame(width: 3) } }
                .accessibilityAddTraits(style == .heading || style == .subheading ? .isHeader : [])
        case .image(let url, let alt, let link, let original):
            if let link {
                Link(destination: link) { ArticlePhoto(url: url, alt: alt, originalSize: original, aspectRatio: imageRatios[url] ?? 16 / 9, cache: cache) }
            } else { ArticlePhoto(url: url, alt: alt, originalSize: original, aspectRatio: imageRatios[url] ?? 16 / 9, cache: cache) }
        case .video(let url, let poster):
            ArticleVideo(url: url, poster: poster, cache: cache).id(url)
        case .youtube(let id):
            YouTubeBlock(id: id).id(id)
        }
    }


}

private struct ArticlePhoto: View {
    let url: URL
    let alt: String
    var originalSize = false
    var aspectRatio: Double = 16 / 9
    var cache = MediaCache.shared
    @State private var bitmap: CGImage?
    @State private var failed = false
    var body: some View {
        Color.clear
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                if let bitmap {
                    Image(bitmap, scale: 1, label: Text(alt.isEmpty ? "Article image" : alt))
                        .resizable().scaledToFit()
                        .frame(maxWidth: originalSize ? CGFloat(bitmap.width) : .infinity)
                } else if failed {
                    Link(alt.isEmpty ? "Open image" : alt, destination: url)
                } else { ProgressView() }
            }
        .accessibilityLabel(alt.isEmpty ? "Article image" : alt)
        .task(id: url) {
            bitmap = nil; failed = false
            do {
                let entry = try await cache.entry(for: url)
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
    var cache = MediaCache.shared
    @State private var player: AVPlayer?
    @State private var playing = false
    var body: some View {
        Group {
            if let player { VideoPlayer(player: player) }
            else {
                Button { playing = true } label: {
                    ZStack {
                        Color.black
                        if let poster { ArticlePhoto(url: poster, alt: "Video poster", cache: cache) }
                        Image(systemName: "play.circle.fill").font(.largeTitle).foregroundStyle(.white)
                    }
                }.buttonStyle(.plain).accessibilityLabel("Play video")
                .highPriorityGesture(DragGesture(minimumDistance: 10))
            }
        }.aspectRatio(16/9, contentMode: .fit)
        .task(id: playing) {
            guard playing else { return }
            let local = await cache.cachedFile(for: url)
            guard !Task.isCancelled else { return }
            let video = AVPlayer(url: local ?? url)
            player = video; video.play()
            if local == nil { _ = try? await cache.entry(for: url) }
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
            else {
                Button("Play YouTube video", systemImage: "play.rectangle.fill") { showing = true }
                    .highPriorityGesture(DragGesture(minimumDistance: 10))
            }
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

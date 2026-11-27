#if SWIFT_PACKAGE
import ReaderContent
#endif
import Foundation
import SwiftSoup
import SwiftUI

struct ReaderPage: Sendable {
    let input: Input
    enum Content: Sendable {
        case native(NativeArticleBody)
        case web(String)
    }
    let content: Content
    var nativeBody: NativeArticleBody? {
        if case .native(let body) = content { return body }
        return nil
    }
    let reusedBody: Bool
    var displayBody: NativeArticleBody? = nil
    var displayTitle: String? = nil
    var displayText: [Int: AttributedString] = [:]
    var imageRatios: [URL: Double] = [:]

    struct Input: Equatable, Sendable {
        let article: ReaderDocument
        let hiddenText: String
        let palette: ReaderPalette
        let version: Int
    }
    static func visible(for input: Input, launch: Self?, prepared: Self?) -> Self? {
        if let launch, launch.input == input { return launch }
        guard let prepared else { return nil }
        if prepared.input.article.key == input.article.key && prepared.input.hiddenText != input.hiddenText { return nil }
        return prepared
    }
    static func imageAspectRatios(html: String) -> [URL: Double] {
        guard let images = try? SwiftSoup.parse(html).select("img[width][height]") else { return [:] }
        var ratios: [URL: Double] = [:]
        for image in images.array() {
            let original = (try? image.attr("data-reader-src")) ?? ""
            guard let raw = try? image.attr("src"), let url = URL(string: original.isEmpty ? raw : original),
                  let w = try? image.attr("width"), let width = Double(w),
                  let h = try? image.attr("height"), let height = Double(h),
                  width.isFinite, height.isFinite, width > 0, height > 0,
                  (width / height).isFinite else { continue }
            ratios[url] = width / height
        }
        return ratios
    }

    static func prepare(_ input: Input, cache: MediaCache = .shared) async -> ReaderPage {
        let article = input.article
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let formatted = try? await cache.formattedBody(article, hiddenText: input.hiddenText)
        if let formatted, let blocks = formatted.nativeBody {
            // Prepare once away from the main actor, never during SwiftUI updates.
            let display = await Task.detached(priority: .userInitiated) {
                let title = ReaderHyphenation.text(article.title,
                    language: ReaderHyphenation.language(for: article.title + " " + article.text))
                let body = NativeArticleBody(blocks: blocks.blocks.map { block in
                    guard case .text(let style, let runs) = block else { return block }
                    let language = ReaderHyphenation.language(for: runs.map(\.text).joined())
                    return .text(style, runs.map { run in
                        var displayed = run
                        displayed.text = ReaderHyphenation.text(run.text, language: language)
                        return displayed
                    })
                })
                var text: [Int: AttributedString] = [:]
                for (index, block) in body.blocks.enumerated() {
                    guard case .text(_, let runs) = block else { continue }
                    var result = AttributedString()
                    for run in runs {
                        var span = AttributedString(run.text)
                        var intent: InlinePresentationIntent = []
                        if run.bold { intent.insert(.stronglyEmphasized) }
                        if run.italic { intent.insert(.emphasized) }
                        span.inlinePresentationIntent = intent
                        span.link = run.link
                        if run.link != nil { span.underlineStyle = .single }
                        result.append(span)
                    }
                    text[index] = result
                }
                let ratios = imageAspectRatios(html: formatted.html)
                return (title, body, text, ratios)
            }.value
            return ReaderPage(input: input, content: .native(blocks), reusedBody: formatted.reused,
                              displayBody: display.1, displayTitle: display.0, displayText: display.2, imageRatios: display.3)
        }
        let body = formatted?.html ?? "<p>" + escape(article.text).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        let language = ReaderHyphenation.language(for: article.title + " " + ((try? SwiftSoup.parse(body).text()) ?? article.text))
        let headline = ContentRules.isTelegram(article.url) ? "" : "<h1>\(escape(article.title))</h1>"
        let html = """
        <!doctype html><html lang="\(escape(language))" data-reader-key="\(escape(article.key))"><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src https: data: reader-media:; media-src https: reader-media:; frame-src https://www.youtube-nocookie.com; style-src 'unsafe-inline'; script-src 'none'; base-uri 'none'; form-action 'none'">
        <style>
        \(ReaderAppearance.stylesheet(input.palette))
        body { margin:0 auto; padding:0 24px 24px; max-width:680px; overflow-wrap:anywhere; }
        /* Fill the reader column even when publisher HTML supplies small dimensions. */
        img { display:block; width:100%; max-width:100%; height:auto; border-radius:6px; }
        img[data-reader-original] { width:auto; }
        video, iframe { display:block; width:100%; height:auto; aspect-ratio:16/9; border:0; background:#181818; object-fit:contain; }
        /* Reserve space while loading, then use the photo’s intrinsic proportions. */
        img:not([width][height]) { aspect-ratio:auto 16/9; }
        figure { margin:1.5em 0; } figcaption,header,footer { font: -apple-system-caption1; color: inherit; }
        a { color: inherit; text-underline-offset:0.16em; } blockquote { border-left:3px solid #298c81; margin:1em 0; padding-left:1em; }
        button[popovertarget] { appearance:none; border:0; padding:0; background:none; color:inherit; font:inherit; text-align:inherit; text-decoration:underline dotted; text-underline-offset:0.16em; cursor:pointer; }
        [popover] { box-sizing:border-box; max-width:min(26em, calc(100% - 48px)); max-height:calc(100% - 48px); overflow:auto; padding:0.75em 1em; border:1px solid currentColor; border-radius:8px; color:CanvasText; background:Canvas; }
        pre { overflow-x:auto; padding:12px; background:light-dark(#f3f3f3,#252525); } table { display:block; overflow-x:auto; border-collapse:collapse; }
        td,th { border:1px solid GrayText; padding:8px; } footer { margin-top:32px; }
        </style></head><body><header>\(escape(article.source)) · \(escape(article.published.formatted(date: .abbreviated, time: .omitted)))</header>
        \(headline)<article>\(body)</article>
        <footer><a data-reader-original-link href="\(escape(article.url))">Original article</a></footer></body></html>
        """
        return ReaderPage(input: input, content: .web(html), reusedBody: formatted?.reused == true)
    }
}

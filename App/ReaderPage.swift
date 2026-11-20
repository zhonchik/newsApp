#if SWIFT_PACKAGE
import ReaderContent
#endif
import Foundation

struct ReaderPage: Sendable {
    let input: Input
    let html: String
    let nativeBody: NativeArticleBody?
    let reusedBody: Bool

    struct Input: Equatable, Sendable {
        let article: ReaderDocument
        let hiddenText: String
        let palette: ReaderPalette
        let version: Int
    }
    static func prepare(_ input: Input, cache: MediaCache = .shared) async -> ReaderPage {
        let article = input.article
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let formatted = try? await cache.formattedBody(article, hiddenText: input.hiddenText)
        let body = formatted?.html ?? "<p>" + escape(article.text).replacingOccurrences(of: "\n", with: "<br>") + "</p>"
        let headline = ContentRules.isTelegram(article.url) ? "" : "<h1>\(escape(article.title))</h1>"
        let html = """
        <!doctype html><html data-reader-key="\(escape(article.key))"><head><meta name="viewport" content="width=device-width, initial-scale=1">
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
        pre { overflow-x:auto; padding:12px; background:light-dark(#f3f3f3,#252525); } table { display:block; overflow-x:auto; border-collapse:collapse; }
        td,th { border:1px solid GrayText; padding:8px; } footer { margin-top:32px; }
        </style></head><body><header>\(escape(article.source)) · \(escape(article.published.formatted(date: .abbreviated, time: .omitted)))</header>
        \(headline)<article>\(body)</article>
        <footer><a href="\(escape(article.url))">Read original</a></footer></body></html>
        """
        return ReaderPage(input: input, html: html, nativeBody: formatted?.nativeBody, reusedBody: formatted?.reused == true)
    }
}

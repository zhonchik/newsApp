#if SWIFT_PACKAGE
import ReaderContent
#endif
import Foundation
import SwiftSoup

/// Parsed from the reader's sanitized DOM, before WebKit-specific URL rewriting.
struct NativeArticleBody: Codable, Equatable, Sendable {
    enum Style: String, Codable { case paragraph, heading, subheading, caption, quote }
    struct Run: Codable, Equatable, Sendable {
        var text: String
        var bold = false
        var italic = false
        var link: URL?
    }
    enum Block: Codable, Equatable, Sendable {
        case text(Style, [Run])
        case image(URL, alt: String, link: URL?, originalSize: Bool)
        case video(URL, poster: URL?)
        case youtube(String)
    }
    let blocks: [Block]

    static func parse(_ root: Element) throws -> Self? {
        var blocks: [Block] = []
        var runs: [Run] = []
        func flush(_ style: Style) {
            if runs.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                blocks.append(.text(style, runs))
            }
            runs = []
        }
        func url(_ raw: String) -> URL? {
            guard let parsed = URL(string: raw), ["https", "http"].contains(parsed.scheme?.lowercased() ?? ""), parsed.host != nil else { return nil }
            return parsed
        }
        func walk(_ node: Node, style: Style, format: Run) throws -> Bool {
            if let text = node as? TextNode {
                var run = format
                run.text = text.getWholeText().replacingOccurrences(of: "[ \\r\\t\\n]+", with: " ", options: .regularExpression)
                if runs.isEmpty || runs.last?.text.last?.isWhitespace == true {
                    if run.text.first == " " { run.text.removeFirst() }
                }
                if !run.text.isEmpty { runs.append(run) }
                return true
            }
            guard let e = node as? Element else { return true }
            let tag = e.tagName()
            var nested = format
            var next = style
            var boundary = true
            switch tag {
            case "body", "p", "div", "figure": break
            case "h1", "h2": next = .heading
            case "h3", "h4", "h5", "h6": next = .subheading
            case "blockquote": next = .quote
            case "figcaption": next = .caption
            case "b", "strong": nested.bold = true; boundary = false
            case "i", "em": nested.italic = true; boundary = false
            case "span": boundary = false
            case "a": nested.link = url(try e.attr("href")); boundary = false
            case "br":
                runs.append(Run(text: "\n")); return true
            case "img":
                guard let src = url(try e.attr("src")) else { return false }
                flush(style)
                blocks.append(.image(src, alt: try e.attr("alt"), link: format.link, originalSize: e.hasAttr("data-reader-original")))
                return true
            case "video":
                let src = try e.attr("src")
                guard let address = url(src.isEmpty ? try e.select("source[src]").first()?.attr("src") ?? "" : src) else { return false }
                flush(style)
                blocks.append(.video(address, poster: url(try e.attr("poster"))))
                return true
            case "iframe":
                guard let id = VideoPreview.youtubeID(try e.attr("src")) else { return false }
                flush(style)
                blocks.append(.youtube(id))
                return true
            default: return false
            }
            if boundary { flush(style) }
            for child in e.getChildNodes() {
                if try !walk(child, style: next, format: nested) { return false }
            }
            if boundary { flush(next) }
            return true
        }
        guard try walk(root, style: .paragraph, format: Run(text: "")), !blocks.isEmpty else { return nil }
        return Self(blocks: blocks)
    }
}

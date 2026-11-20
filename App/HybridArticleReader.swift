import SwiftUI

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
    @State private var prepared: ReaderPage?

    private var input: ReaderPage.Input? {
        article.map { ReaderPage.Input(article: $0, hiddenText: hiddenText,
            palette: ReaderPalette(lightText: lightText, lightBackground: lightBackground, darkText: darkText, darkBackground: darkBackground),
            version: renderVersion) }
    }
    var body: some View {
        Group {
            if let input, let page = ReaderPage.visible(for: input, launch: launchPage, prepared: prepared) {
                let isRequestedPage = page.input == input
                if let native = page.nativeBody {
                    NativeArticleView(content: native, article: page.input.article, palette: page.input.palette, onDisplay: { if isRequestedPage { onDisplay("Native") } }, reload: { if isRequestedPage { await reload() } }, move: move)
                        .id(page.input.article.key)
                } else {
                    ArticleWebView(launchPage: page, article: page.input.article, hiddenText: page.input.hiddenText,
                        renderVersion: page.input.version, onDisplay: { if isRequestedPage { onDisplay("WebKit") } },
                        onFailure: { if isRequestedPage { onFailure($0) } }, reload: { if isRequestedPage { await reload() } }, move: move)
                }
            } else { Color.clear.accessibilityHidden(true) }
        }
        .task(id: input) {
            guard let input, prepared?.input != input else { return }
            if let launchPage, launchPage.input == input {
                prepared = launchPage
                return
            }
            let page = await ReaderPage.prepare(input)
            if !Task.isCancelled { prepared = page }
        }
    }

}

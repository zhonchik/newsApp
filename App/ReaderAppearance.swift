enum ReaderAppearance {
    static func stylesheet(_ palette: ReaderPalette) -> String {
        """
        :root { color-scheme: light dark; font: -apple-system-body; }
        body { color: \(ReaderPalette.valid(palette.lightText, fallback: "#202020")); background: \(ReaderPalette.valid(palette.lightBackground, fallback: "#FFFFFF")); }
        @media (prefers-color-scheme: dark) { body { color: \(ReaderPalette.valid(palette.darkText, fallback: "#DEDCD8")); background: \(ReaderPalette.valid(palette.darkBackground, fallback: "#181818")); } }
        article, h1 { font-family:ui-serif, Georgia, serif; }
        article { font-size:1.15em; line-height:1.7; }
        article p { margin-block:0 1em; }
        @media (prefers-color-scheme: dark) {
            article { font-weight:350; }
            article :is(strong,b) { font-weight:700; }
        }
        @media (prefers-color-scheme: dark) and (prefers-contrast: more) {
            article { font-weight:400; }
        }
        h1 { font-size:1.4em; line-height:1.3; }
        h2,h3,h4 { line-height:1.3; }
        """
    }
}

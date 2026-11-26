import Foundation
import NaturalLanguage
import CoreFoundation

struct ReaderPalette: Sendable, Equatable {
    let lightText: String
    let lightBackground: String
    let darkText: String
    let darkBackground: String
    static func saved(in defaults: UserDefaults = .standard) -> Self {
        Self(lightText: defaults.string(forKey: "lightText") ?? "#202020",
             lightBackground: defaults.string(forKey: "lightBackground") ?? "#FFFFFF",
             darkText: defaults.string(forKey: "darkText") ?? "#DEDCD8",
             darkBackground: defaults.string(forKey: "darkBackground") ?? "#181818")
    }
    static func valid(_ value: String, fallback: String) -> String {
        value.range(of: "^#[0-9A-Fa-f]{6}$", options: .regularExpression) == nil ? fallback : value
    }
}

enum ReaderAppearance {
    static let bodyScale = 1.15
    static let lineHeight = 1.7
    static let darkWeight = 350
    static let regularWeight = 400

    static func bodyWeight(dark: Bool, increasedContrast: Bool) -> Int {
        dark && !increasedContrast ? darkWeight : regularWeight
    }

    static func stylesheet(_ palette: ReaderPalette) -> String {
        """
        :root { color-scheme: light dark; font: -apple-system-body; }
        body { color: \(ReaderPalette.valid(palette.lightText, fallback: "#202020")); background: \(ReaderPalette.valid(palette.lightBackground, fallback: "#FFFFFF")); }
        @media (prefers-color-scheme: dark) { body { color: \(ReaderPalette.valid(palette.darkText, fallback: "#DEDCD8")); background: \(ReaderPalette.valid(palette.darkBackground, fallback: "#181818")); } }
        article, h1 { font-family:ui-serif, Georgia, serif; }
        article { font-size:\(bodyScale)em; line-height:\(lineHeight); }
        article p { margin-block:0 1em; }
        article, h1 { -webkit-hyphens:auto; hyphens:auto; }
        pre, code, kbd, samp { -webkit-hyphens:none; hyphens:none; }
        @media (prefers-color-scheme: dark) {
            article { font-weight:\(darkWeight); }
            article :is(strong,b) { font-weight:700; }
        }
        @media (prefers-color-scheme: dark) and (prefers-contrast: more) {
            article { font-weight:\(regularWeight); }
        }
        h1 { font-size:1.4em; line-height:1.3; }
        h2,h3,h4 { line-height:1.3; }
        """
    }
}

/// Discretionary breaks affect layout only; persisted article text remains untouched.
enum ReaderHyphenation {
    static func language(for text: String) -> String {
        NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue
            ?? Locale.current.language.languageCode?.identifier ?? "und"
    }

    static func text(_ text: String, language: String) -> String {
        let locale = NSLocale(localeIdentifier: language) as CFLocale
        guard CFStringIsHyphenationAvailableForLocale(locale) else { return text }
        let source = text as NSString
        let result = NSMutableString(string: text)
        // Walk backwards so inserted characters cannot shift pending UTF-16 offsets.
        var before = source.length
        while before > 0 {
            let offset = CFStringGetHyphenationLocationBeforeIndex(
                text as CFString, before, CFRange(location: 0, length: source.length), 0, locale, nil
            )
            guard offset != kCFNotFound, offset > 0, offset < before else { break }
            result.insert("\u{00AD}", at: offset)
            before = offset
        }
        return result as String
    }

}

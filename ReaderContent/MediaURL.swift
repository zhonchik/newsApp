import Foundation

public enum MediaURL {
    /// Repair the exact duplicated-origin defect present in F1News RSS images.
    /// Do not strip nested URLs in valid paths/queries or guess at other hosts.
    public static func resolve(_ raw: String, baseURL: String? = nil) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let origin = "https://c.f1news.ru"
        if value.hasPrefix(origin + origin + "/") { value.removeFirst(origin.count) }
        guard !value.isEmpty,
              let absolute = URL(string: value, relativeTo: baseURL.flatMap(URL.init(string:)))?.absoluteURL,
              var parts = URLComponents(url: absolute, resolvingAgainstBaseURL: true),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil else { return nil }
        // Foundation may accept an empty port in a concatenated origin as a URL.
        let authority = absolute.absoluteString.dropFirst(8).prefix { !"/?#".contains($0) }
        guard !authority.hasSuffix(":"), parts.port.map({ (1...65535).contains($0) }) ?? true else { return nil }
        parts.scheme = "https"
        return parts.url?.absoluteString
    }
}

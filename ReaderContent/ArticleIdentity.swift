import Foundation

public enum ArticleIdentity {
    /// A publisher URL identifies a story independently of subscription instances.
    public static func key(url: String, fallback: String = "") -> String {
        guard var parts = URLComponents(string: url), parts.host != nil else { return fallback }
        parts.host = parts.host?.lowercased()
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter {
            !$0.name.lowercased().hasPrefix("utm_") && !["fbclid", "gclid"].contains($0.name.lowercased())
        }.sorted { ($0.name, $0.value ?? "") < ($1.name, $1.value ?? "") }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        return parts.string ?? url
    }
    public static func imageKey(_ raw: String) -> String {
        guard let url = URL(string: raw) else { return raw }
        let path = url.path
        // MacRumors serves one original through many hash/size/crop CDN paths.
        if url.host?.hasSuffix("macrumors.com") == true, let range = path.range(of: "/article-new/") {
            return String(path[range.lowerBound...])
        }
        return path
    }
}

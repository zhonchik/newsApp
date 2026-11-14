import Foundation

public enum MediaRequest {
    public static func cachedURL(_ raw: String) -> String? {
        guard var parts = URLComponents(string: raw), parts.scheme == "https", parts.host != nil else { return nil }
        parts.scheme = "reader-media"
        return parts.string
    }
    public static func remoteURL(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "reader-media", parts.host != nil else { return nil }
        parts.scheme = "https"
        return parts.url
    }
    /// A single HTTP byte range, including suffix and open-ended requests.
    public static func range(_ header: String?, size: Int) -> Range<Int>? {
        guard size > 0 else { return nil }
        guard let header else { return 0..<size }
        guard header.hasPrefix("bytes="), !header.contains(",") else { return nil }
        let bounds = header.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2 else { return nil }
        if bounds[0].isEmpty {
            guard let suffix = Int(bounds[1]), suffix > 0 else { return nil }
            return max(0, size - suffix)..<size
        }
        guard let start = Int(bounds[0]), start >= 0, start < size else { return nil }
        let end = bounds[1].isEmpty ? size - 1 : (Int(bounds[1]) ?? -1)
        guard end >= start else { return nil }
        return start..<(min(end, size - 1) + 1)
    }
}

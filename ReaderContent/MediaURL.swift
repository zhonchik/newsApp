import Foundation

public enum MediaURL {
    /// Prefer the feed's own URL when a sized rendition contains its full image path.
    public static func originalImage(for source: String, in feedImages: [String]) -> String? {
        guard !feedImages.isEmpty,
              let rendition = URLComponents(string: source), let host = rendition.host?.lowercased() else { return nil }
        return feedImages.first { image in
            guard let original = URLComponents(string: image),
                  original.host?.lowercased() == host, original.scheme == rendition.scheme,
                  (original.port ?? 443) == (rendition.port ?? 443),
                  original.percentEncodedPath.count > 1,
                  rendition.percentEncodedPath.hasSuffix(original.percentEncodedPath) else { return false }
            let prefix = rendition.percentEncodedPath.dropLast(original.percentEncodedPath.count)
            return prefix.range(of: #"/[0-9]+x[0-9]+$"#, options: .regularExpression) != nil
        }
    }

    /// Repair a repeated HTTPS origin at the start of a URL.
    public static func resolve(_ raw: String, baseURL: String? = nil) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let duplicate = value.range(of: #"^(https://[A-Za-z0-9.-]+(?::[0-9]+)?)(?=\1/)"#, options: .regularExpression) {
            value.removeSubrange(duplicate)
        }
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

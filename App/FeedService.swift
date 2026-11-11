import Foundation

struct FeedService {
    let base: URL
    func request(path: String, query: [URLQueryItem]) async throws -> Data {
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        components.queryItems = query
        guard let url = components.url else { throw URLError(.badURL) }
        var request = URLRequest(url: url); request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONDecoder().decode([String: String].self, from: data))?["error"] ?? "The reading service is unavailable."
            throw NSError(domain: "Current", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        }
        return data
    }
    func items(for subscription: Subscription) async throws -> [RemoteArticle] {
        let data = try await request(path: "feed", query: [.init(name: "kind", value: subscription.kind), .init(name: "url", value: subscription.address)])
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .custom { decoder in
            let raw = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: raw) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            guard let date = formatter.date(from: raw) else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid publication date")) }
            return date
        }
        return try decoder.decode([RemoteArticle].self, from: data)
    }
    func articleText(url: String) async throws -> String {
        let data = try await request(path: "article", query: [.init(name: "url", value: url)])
        struct Body: Decodable { let text: String }
        return try JSONDecoder().decode(Body.self, from: data).text
    }
}

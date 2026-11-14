import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// An in-memory, bounded cache for conditional HTTP response bodies.
/// It deliberately has no persistence and keys entries by HTTP method and full URL.
public actor ConditionalHTTPResponseCache {
    public static let shared = ConditionalHTTPResponseCache()

    public let maximumBodyBytes: Int
    public let maximumTotalBytes: Int

    private struct Entry {
        let body: Data
        let headers: [String: String]
        let etag: String?
        let lastModified: String?
        var lastUsed: UInt64
    }

    private var entries: [String: Entry] = [:]
    private var totalBytes = 0
    private var clock: UInt64 = 0

    public init(maximumBodyBytes: Int = 1_048_576, maximumTotalBytes: Int = 8_388_608) {
        self.maximumBodyBytes = max(0, maximumBodyBytes)
        self.maximumTotalBytes = max(0, maximumTotalBytes)
    }

    /// Performs a request with validators from the local entry and reuses its body on 304.
    /// A 304 without a local body is always an error; it is never converted into success.
    public func fetch(_ request: URLRequest, using session: URLSession) async throws -> (data: Data, response: HTTPURLResponse, reused304: Bool) {
        let key = Self.key(for: request)
        var conditionalRequest = request
        if let entry = entries[key] {
            if let etag = entry.etag { conditionalRequest.setValue(etag, forHTTPHeaderField: "If-None-Match") }
            if let lastModified = entry.lastModified { conditionalRequest.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
        }

        let (data, response) = try await session.data(for: conditionalRequest)
        guard let http = response as? HTTPURLResponse else { throw QuoteSourceError.malformedResponse }
        if http.statusCode == 304 {
            guard let entry = entries[key] else { throw QuoteSourceError.conditionalResponseWithoutCachedBody }
            clock &+= 1
            entries[key]?.lastUsed = clock
            let headers = entry.headers
            guard let url = request.url,
                  let reusedResponse = HTTPURLResponse(url: url, statusCode: 200,
                                                       httpVersion: nil, headerFields: headers) else {
                throw QuoteSourceError.malformedResponse
            }
            return (entry.body, reusedResponse, true)
        }

        guard (200..<300).contains(http.statusCode) else {
            return (data, http, false)
        }

        store(data: data, response: http, key: key)
        return (data, http, false)
    }

    public func entryCount() -> Int { entries.count }
    public func storedByteCount() -> Int { totalBytes }

    private func store(data: Data, response: HTTPURLResponse, key: String) {
        remove(key: key)
        guard !data.isEmpty, data.count <= maximumBodyBytes, data.count <= maximumTotalBytes else { return }
        clock &+= 1
        let headers = Self.stringHeaders(response.allHeaderFields)
        let entry = Entry(body: data, headers: headers,
                          etag: Self.header("ETag", in: headers),
                          lastModified: Self.header("Last-Modified", in: headers), lastUsed: clock)
        while totalBytes + data.count > maximumTotalBytes, let victim = entries.min(by: { $0.value.lastUsed < $1.value.lastUsed })?.key {
            remove(key: victim)
        }
        entries[key] = entry
        totalBytes += data.count
    }

    private func remove(key: String) {
        if let old = entries.removeValue(forKey: key) { totalBytes -= old.body.count }
    }

    private static func key(for request: URLRequest) -> String {
        "\(request.httpMethod ?? "GET") \(request.url?.absoluteString ?? "")"
    }

    private static func stringHeaders(_ fields: [AnyHashable: Any]) -> [String: String] {
        fields.reduce(into: [:]) { result, item in
            if let key = item.key as? String { result[key] = String(describing: item.value) }
        }
    }

    private static func header(_ name: String, in headers: [String: String]) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

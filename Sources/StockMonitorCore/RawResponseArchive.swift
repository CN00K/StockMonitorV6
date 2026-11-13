import Foundation

public enum RawResponseArchiveLimits {
    public static let retention: TimeInterval = 7 * 24 * 60 * 60
    public static let maximumStoredResponses = 500
    public static let maximumStoredBytes = 10 * 1024 * 1024
    public static let maximumResponseBytes = 512 * 1024
    public static let maximumResponsesPerRefresh = 16
    public static let maximumBytesPerRefresh = 2 * 1024 * 1024
}

/// A successful public HTTP response body, with request query and headers intentionally omitted.
public struct RawEventResponse: Sendable, Equatable {
    public let sourceID: String
    public let url: URL
    public let fetchedAt: Date
    public let statusCode: Int
    public let contentType: String?
    public let data: Data

    public init(sourceID: String, url: URL, fetchedAt: Date = Date(), statusCode: Int = 200,
                contentType: String? = nil, data: Data) {
        self.sourceID = sourceID
        self.url = url
        self.fetchedAt = fetchedAt
        self.statusCode = statusCode
        self.contentType = contentType
        self.data = data
    }

    public var sanitizedEndpoint: String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.host.map { "https://\($0)/" } ?? "unknown"
        }
        components.query = nil
        components.fragment = nil
        components.user = nil
        components.password = nil
        return components.string ?? "https://\(url.host ?? "unknown")/"
    }
}

public struct RawResponseArchiveRecord: Sendable, Equatable, Identifiable {
    public let id: String
    public let sourceID: String
    public let endpoint: String
    public let fetchedAt: Date
    public let statusCode: Int
    public let contentType: String?
    public let payload: Data

    public init(id: String, sourceID: String, endpoint: String, fetchedAt: Date,
                statusCode: Int, contentType: String?, payload: Data) {
        self.id = id
        self.sourceID = sourceID
        self.endpoint = endpoint
        self.fetchedAt = fetchedAt
        self.statusCode = statusCode
        self.contentType = contentType
        self.payload = payload
    }

    public var byteCount: Int { payload.count }
}

public struct RawResponseArchiveStats: Sendable, Equatable {
    public let responseCount: Int
    public let byteCount: Int
    public let oldestResponseAt: Date?
    public let newestResponseAt: Date?

    public init(responseCount: Int, byteCount: Int, oldestResponseAt: Date?, newestResponseAt: Date?) {
        self.responseCount = max(0, responseCount)
        self.byteCount = max(0, byteCount)
        self.oldestResponseAt = oldestResponseAt
        self.newestResponseAt = newestResponseAt
    }
}

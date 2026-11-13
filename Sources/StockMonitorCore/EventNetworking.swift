import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum EventNetworkError: Error, LocalizedError, Equatable {
    case invalidURL
    case nonHTTPResponse
    case httpStatus(Int)
    case responseTooLarge(Int)
    case invalidJSON
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid event-source URL"
        case .nonHTTPResponse: return "Event source returned a non-HTTP response"
        case .httpStatus(let status): return "Event source returned HTTP \(status)"
        case .responseTooLarge(let size): return "Event-source response exceeded the size limit (\(size) bytes)"
        case .invalidJSON: return "Event source returned malformed JSON"
        case .provider(let message): return message
        }
    }
}

public struct EventHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let contentType: String?

    public init(data: Data, statusCode: Int, contentType: String?) {
        self.data = data
        self.statusCode = statusCode
        self.contentType = contentType
    }
}

/// Small, bounded HTTP client. Callers only invoke it in foreground/user-requested paths.
public struct PublicEventHTTPClient: Sendable {
    private let budget: RequestBudget
    private let session: URLSession
    private let maximumResponseBytes: Int

    public init(budget: RequestBudget, session: URLSession = .shared,
                maximumResponseBytes: Int = 4_000_000) {
        self.budget = budget
        self.session = session
        self.maximumResponseBytes = max(1_024, maximumResponseBytes)
    }

    public func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 12) async throws -> EventHTTPResponse {
        var request = URLRequest(url: url, timeoutInterval: min(30, max(2, timeout)))
        request.httpMethod = "GET"
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await execute(request)
    }

    public func postForm(_ url: URL, fields: [(String, String)], headers: [String: String] = [:],
                         timeout: TimeInterval = 15) async throws -> EventHTTPResponse {
        var components = URLComponents()
        components.queryItems = fields.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let body = components.percentEncodedQuery?.data(using: .utf8) else { throw EventNetworkError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: min(30, max(2, timeout)))
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try await execute(request)
    }

    private func execute(_ request: URLRequest) async throws -> EventHTTPResponse {
        guard let host = request.url?.host else { throw EventNetworkError.invalidURL }
        try await budget.acquire(host: host)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw EventNetworkError.nonHTTPResponse }
        guard (200..<300).contains(http.statusCode) else { throw EventNetworkError.httpStatus(http.statusCode) }
        guard data.count <= maximumResponseBytes else { throw EventNetworkError.responseTooLarge(data.count) }
        return EventHTTPResponse(data: data, statusCode: http.statusCode,
                                 contentType: http.value(forHTTPHeaderField: "Content-Type"))
    }
}

public enum EventParsing {
    public static func object(_ data: Data) throws -> [String: Any] {
        guard let value = try? JSONSerialization.jsonObject(with: data), let object = value as? [String: Any] else {
            throw EventNetworkError.invalidJSON
        }
        return object
    }

    public static func string(_ value: Any?) -> String? {
        guard let value else { return nil }
        if value is NSNull { return nil }
        if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    public static func int(_ value: Any?) -> Int? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    public static func double(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    public static func date(_ value: Any?, formats: [String] = ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd"]) -> Date? {
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        guard let text = string(value) else { return nil }
        if let epoch = Double(text) {
            return Date(timeIntervalSince1970: epoch > 10_000_000_000 ? epoch / 1_000 : epoch)
        }
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
            formatter.dateFormat = format
            if let parsed = formatter.date(from: text) { return parsed }
        }
        let iso = ISO8601DateFormatter()
        return iso.date(from: text)
    }

    public static func stripHTML(_ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]*>") else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

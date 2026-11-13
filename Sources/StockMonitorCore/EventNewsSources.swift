import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

public struct CLSTelegraphSource: MarketEventSource {
    public let identifier = "cls"
    private let client: PublicEventHTTPClient

    public init(budget: RequestBudget) { client = PublicEventHTTPClient(budget: budget) }

    public func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        let lastTime = String(Int(since.timeIntervalSince1970))
        let parameters = [
            "appName": "CailianpressWeb", "last_time": lastTime, "os": "web",
            "refresh_type": "1", "rn": String(min(50, max(1, limit))), "sv": "7.7.5"
        ]
        do {
            let url = try Self.signedURL(parameters)
            let response = try await client.get(url, headers: [
                "User-Agent": "Mozilla/5.0", "Referer": "https://www.cls.cn/"
            ])
            let root = try EventParsing.object(response.data)
            if let errno = EventParsing.int(root["errno"]), errno != 0 {
                throw EventNetworkError.provider("CLS errno=\(errno): \(EventParsing.string(root["msg"]) ?? "provider error")")
            }
            guard let data = root["data"] as? [String: Any],
                  let rows = data["roll_data"] as? [[String: Any]] else {
                throw EventNetworkError.provider("CLS response did not contain data.roll_data")
            }
            let parsed = rows.compactMap { Self.parseRow($0) }
            let events = parsed.filter { ($0.publishedAt ?? .distantPast) >= since }
                .prefix(max(1, limit))
            let result = Array(events)
            return EventFetchBatch(events: result, status: EventSourceStatus(sourceID: identifier,
                latestPublishedAt: result.compactMap(\.publishedAt).max(), requestedCount: limit,
                returnedCount: result.count, requestCount: 1, successfulRequestCount: 1,
                candidateRecordCount: rows.count, validRecordCount: parsed.count,
                note: "Public signed endpoint; undocumented and may change. Ads are excluded."),
                rawResponses: [RawEventResponse(sourceID: identifier, url: url, contentType: response.contentType, data: response.data)])
        } catch {
            return failedStatus(sourceID: identifier, requested: limit, error: error,
                note: "CLS public endpoint unavailable or schema/signature changed; no data was inferred.")
        }
    }

    public static func parseRow(_ row: [String: Any], fetchedAt: Date = Date()) -> MarketEvent? {
        if EventParsing.int(row["is_ad"]) == 1 { return nil }
        let titleValue = EventParsing.string(row["title"])
        let brief = EventParsing.string(row["brief"])
        let content = EventParsing.string(row["content"])
        guard let title = titleValue ?? brief ?? content?.prefix(120).description else { return nil }
        let subjects = (row["subjects"] as? [[String: Any]] ?? []).compactMap { EventParsing.string($0["subject_name"]) }
        let codes = (row["stock_list"] as? [[String: Any]] ?? []).compactMap {
            EventParsing.string($0["secu_code"]) ?? EventParsing.string($0["stock_code"]) ?? EventParsing.string($0["code"])
        }.map(normalizeCode)
        let timestamp = EventParsing.date(row["ctime"])
        return MarketEvent(kind: .news, sourceID: "cls", sourceItemID: EventParsing.string(row["id"]),
            title: title, body: content ?? brief, url: EventParsing.string(row["shareurl"]),
            publishedAt: timestamp, fetchedAt: fetchedAt, providerTimestampVerified: timestamp != nil,
            priority: 3, impactScope: !codes.isEmpty ? .stock : !subjects.isEmpty ? .sector : .unknown,
            sectors: subjects, stockCodes: codes)
    }

    private static func signedURL(_ parameters: [String: String]) throws -> URL {
#if canImport(CryptoKit)
        let canonical = parameters.keys.sorted().map { key in "\(key)=\(parameters[key] ?? "")" }.joined(separator: "&")
        let sha1Hex = Insecure.SHA1.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        let signature = Insecure.MD5.hash(data: Data(sha1Hex.utf8)).map { String(format: "%02x", $0) }.joined()
        var components = URLComponents(string: "https://www.cls.cn/v1/roll/get_roll_list")
        components?.queryItems = (parameters.merging(["sign": signature]) { _, new in new })
            .sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components?.url else { throw EventNetworkError.invalidURL }
        return url
#else
        throw EventNetworkError.provider("CLS request signing requires Apple CryptoKit; unavailable on this test host.")
#endif
    }
}

public struct EastmoneyNewsSource: MarketEventSource {
    public let identifier = "eastmoney_news"
    private let client: PublicEventHTTPClient

    public init(budget: RequestBudget) { client = PublicEventHTTPClient(budget: budget) }

    public func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        do {
            // The no-parameter list endpoint returned a public JSON response; observed query variants were inconsistent.
            let url = URL(string: "https://newsapi.eastmoney.com/kuaixun/v2/api/list")!
            let response = try await client.get(url, headers: ["User-Agent": "Mozilla/5.0", "Referer": "https://www.eastmoney.com/"])
            let root = try EventParsing.object(response.data)
            guard let rows = root["news"] as? [[String: Any]] else {
                throw EventNetworkError.provider("Eastmoney news response did not contain a news array")
            }
            let parsed = rows.compactMap { Self.parseRow($0) }
            let events = parsed.filter { ($0.publishedAt ?? .distantPast) >= since }
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                .prefix(max(1, limit))
            let result = Array(events)
            return EventFetchBatch(events: result, status: EventSourceStatus(sourceID: identifier,
                latestPublishedAt: result.compactMap(\.publishedAt).max(), requestedCount: limit,
                returnedCount: result.count, requestCount: 1, successfulRequestCount: 1,
                candidateRecordCount: rows.count, validRecordCount: parsed.count,
                note: "Public, undocumented list/content endpoints; content details are not fetched unless a separate user action is added."),
                rawResponses: [RawEventResponse(sourceID: identifier, url: url, contentType: response.contentType, data: response.data)])
        } catch {
            return failedStatus(sourceID: identifier, requested: limit, error: error,
                note: "Eastmoney news is a best-effort public source; endpoint/schema errors are surfaced.")
        }
    }

    public static func parseRow(_ row: [String: Any], fetchedAt: Date = Date()) -> MarketEvent? {
        guard let title = EventParsing.string(row["title"]) else { return nil }
        let published = EventParsing.date(row["showtime"]) ?? EventParsing.date(row["ordertime"])
        let newsID = EventParsing.string(row["newsid"]) ?? EventParsing.string(row["id"])
        return MarketEvent(kind: .news, sourceID: "eastmoney_news", sourceItemID: newsID,
            title: title, body: EventParsing.string(row["digest"]) ?? EventParsing.string(row["simdigest"]),
            url: EventParsing.string(row["url_unique"]) ?? EventParsing.string(row["url_w"]) ?? EventParsing.string(row["url_m"]),
            publishedAt: published, fetchedAt: fetchedAt, providerTimestampVerified: published != nil,
            priority: 2, impactScope: .unknown)
    }
}

public struct ThePaperNewsSource: MarketEventSource {
    public let identifier = "thepaper"
    private let client: PublicEventHTTPClient

    public init(budget: RequestBudget) { client = PublicEventHTTPClient(budget: budget) }

    public func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        do {
            let url = URL(string: "https://cache.thepaper.cn/contentapi/wwwIndex/rightSidebar")!
            let response = try await client.get(url, headers: ["User-Agent": "Mozilla/5.0", "Referer": "https://www.thepaper.cn/"])
            let root = try EventParsing.object(response.data)
            guard EventParsing.int(root["resultCode"]) == 1,
                  let data = root["data"] as? [String: Any],
                  let rows = data["hotNews"] as? [[String: Any]] else {
                throw EventNetworkError.provider("The Paper response code/data.hotNews was not usable")
            }
            let parsed = rows.compactMap { Self.parseRow($0) }
            let events = parsed.filter { ($0.publishedAt ?? .distantPast) >= since }
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                .prefix(max(1, limit))
            let result = Array(events)
            return EventFetchBatch(events: result, status: EventSourceStatus(sourceID: identifier,
                latestPublishedAt: result.compactMap(\.publishedAt).max(), requestedCount: limit,
                returnedCount: result.count, requestCount: 1, successfulRequestCount: 1,
                candidateRecordCount: rows.count, validRecordCount: parsed.count,
                note: "Public right-sidebar feed; official root page may challenge automated requests."),
                rawResponses: [RawEventResponse(sourceID: identifier, url: url, contentType: response.contentType, data: response.data)])
        } catch {
            return failedStatus(sourceID: identifier, requested: limit, error: error,
                note: "The Paper feed is best-effort; WAF or schema failures are not treated as an empty feed.")
        }
    }

    public static func parseRow(_ row: [String: Any], fetchedAt: Date = Date()) -> MarketEvent? {
        guard let title = EventParsing.string(row["name"]),
              let itemID = EventParsing.string(row["contId"]) else { return nil }
        let published = EventParsing.date(row["pubTimeLong"])
        return MarketEvent(kind: .news, sourceID: "thepaper", sourceItemID: itemID,
            title: title, body: EventParsing.string(row["summary"]), url: EventParsing.string(row["link"]),
            publishedAt: published, fetchedAt: fetchedAt, providerTimestampVerified: published != nil,
            priority: 2, impactScope: .unknown)
    }
}

public struct GovCNPolicySource: MarketEventSource {
    public let identifier = "gov"
    private let client: PublicEventHTTPClient
    private let query: String

    public init(budget: RequestBudget, query: String = "证券") {
        client = PublicEventHTTPClient(budget: budget)
        self.query = query
    }

    public func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        do {
            var components = URLComponents(string: "https://sousuo.www.gov.cn/search-gov/data")!
            components.queryItems = [
                URLQueryItem(name: "t", value: "zhengcelibrary"),
                URLQueryItem(name: "q", value: query),
                URLQueryItem(name: "searchfield", value: "title"),
                URLQueryItem(name: "sort", value: "pubtime"),
                URLQueryItem(name: "sortType", value: "1"),
                URLQueryItem(name: "p", value: "0"),
                URLQueryItem(name: "n", value: String(min(20, max(1, limit)))),
                URLQueryItem(name: "type", value: "gwyzcwjk")
            ]
            guard let url = components.url else { throw EventNetworkError.invalidURL }
            let response = try await client.get(url, headers: ["User-Agent": "Mozilla/5.0", "Referer": "https://www.gov.cn/"])
            let root = try EventParsing.object(response.data)
            guard EventParsing.int(root["code"]) == 200,
                  let search = root["searchVO"] as? [String: Any] else {
                throw EventNetworkError.provider("gov.cn search response code/searchVO was not usable")
            }
            let rows = Self.rows(in: search)
            let parsed = rows.compactMap { Self.parseRow($0) }
            let events = parsed.filter { ($0.publishedAt ?? .distantPast) >= since }
                .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                .prefix(max(1, limit))
            let result = Array(events)
            return EventFetchBatch(events: result, status: EventSourceStatus(sourceID: identifier,
                latestPublishedAt: result.compactMap(\.publishedAt).max(), requestedCount: limit,
                returnedCount: result.count, requestCount: 1, successfulRequestCount: 1,
                candidateRecordCount: rows.count, validRecordCount: parsed.count,
                note: "Official policy-library search for ‘\(query)’; a search result is not a guaranteed news feed."),
                rawResponses: [RawEventResponse(sourceID: identifier, url: url, contentType: response.contentType, data: response.data)])
        } catch {
            return failedStatus(sourceID: identifier, requested: limit, error: error,
                note: "gov.cn public search is best-effort; no official freshness/rate contract was verified.")
        }
    }

    public static func parseRow(_ row: [String: Any], fetchedAt: Date = Date()) -> MarketEvent? {
        guard let rawTitle = EventParsing.string(row["title"]) else { return nil }
        let title = EventParsing.stripHTML(rawTitle)
        guard !title.isEmpty else { return nil }
        let published = EventParsing.date(row["pubtime"]) ?? EventParsing.date(row["ptime"]) ??
            EventParsing.date(row["pubtimeStr"])
        let itemID = EventParsing.string(row["id"]) ?? EventParsing.string(row["url"])
        return MarketEvent(kind: .news, sourceID: "gov", sourceItemID: itemID,
            title: title, body: EventParsing.string(row["summary"]), url: EventParsing.string(row["url"]),
            publishedAt: published, fetchedAt: fetchedAt, providerTimestampVerified: published != nil,
            priority: 5, impactScope: .unknown)
    }

    private static func rows(in search: [String: Any]) -> [[String: Any]] {
        var result: [[String: Any]] = []
        if let catMap = search["catMap"] as? [String: Any] {
            for category in catMap.keys.sorted() {
                guard let group = catMap[category] as? [String: Any] else { continue }
                if let list = group["listVO"] as? [[String: Any]] { result.append(contentsOf: list) }
            }
        }
        if let list = search["listVO"] as? [[String: Any]] { result.append(contentsOf: list) }
        return result
    }
}

public struct XueqiuUnavailableSource: MarketEventSource {
    public let identifier = "xueqiu"
    public init() {}

    public func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        failedStatus(sourceID: identifier, requested: limit,
            error: EventNetworkError.provider("Unavailable: observed public API requests were blocked (403/400016) and a maintained client uses cookie/anti-bot state."),
            requestCount: 0,
            note: "No login, cookie collection, WAF bypass, or synthetic data is used.")
    }
}

public struct MIITUnavailableSource: MarketEventSource {
    public let identifier = "miit"
    public init() {}

    public func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        failedStatus(sourceID: identifier, requested: limit,
            error: EventNetworkError.provider("Unavailable: ordinary requests to MIIT news pages returned HTTP 403 challenge; no stable public feed was verified."),
            requestCount: 0,
            note: "Challenge bypass is intentionally not attempted; an accessible official feed is required.")
    }
}

private func failedStatus(sourceID: String, requested: Int, error: Error,
                          requestCount: Int = 1, note: String) -> EventFetchBatch {
    EventFetchBatch(events: [], status: EventSourceStatus(sourceID: sourceID,
        requestedCount: requested, returnedCount: 0, requestCount: requestCount,
        error: error.localizedDescription, note: note))
}

private func normalizeCode(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let digits = String(trimmed.prefix(while: { $0.isNumber }))
    return digits.count == 6 ? digits : trimmed
}

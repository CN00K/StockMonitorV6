import Foundation

public protocol StockAwareMarketEventSource: MarketEventSource {
    func fetch(since: Date, limit: Int, stockCodes: [String]) async -> EventFetchBatch
}

public extension StockAwareMarketEventSource {
    func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        await fetch(since: since, limit: limit, stockCodes: [])
    }
}

public struct CNInfoAnnouncementSource: StockAwareMarketEventSource {
    public let identifier = "cninfo"
    private let client: PublicEventHTTPClient
    private let now: @Sendable () -> Date

    public init(budget: RequestBudget, now: @escaping @Sendable () -> Date = { Date() }) {
        client = PublicEventHTTPClient(budget: budget)
        self.now = now
    }

    public func fetch(since: Date, limit: Int, stockCodes: [String]) async -> EventFetchBatch {
        let szseCodes = Array(Set(stockCodes.filter(Self.isVerifiedSZSECode))).sorted().prefix(10)
        guard !szseCodes.isEmpty else {
            return EventFetchBatch(events: [], status: EventSourceStatus(sourceID: identifier,
                requestedCount: stockCodes.count, returnedCount: 0, requestCount: 0,
                note: "Only publicly verified SZSE code→orgId mapping is implemented; no broad crawl or unverified SSE mapping is attempted."))
        }
        var requests = 0
        var successfulRequests = 0
        var candidateRows = 0
        var validRows = 0
        var rawResponses: [RawEventResponse] = []
        do {
            let mapURL = URL(string: "https://www.cninfo.com.cn/new/data/szse_stock.json")!
            requests += 1
            let mapResponse = try await client.get(mapURL, headers: [
                "User-Agent": "Mozilla/5.0", "Referer": "https://www.cninfo.com.cn/new/index"
            ])
            rawResponses.append(RawEventResponse(sourceID: identifier, url: mapURL,
                contentType: mapResponse.contentType, data: mapResponse.data))
            let orgIDs = try Self.parseStockMap(mapResponse.data)
            successfulRequests += 1
            var events: [MarketEvent] = []
            var errors: [String] = []
            let until = now()
            for code in szseCodes {
                guard let orgID = orgIDs[code] else {
                    errors.append("No public orgId mapping for \(code)")
                    continue
                }
                do {
                    let fields = Self.queryFields(code: code, orgID: orgID, since: since, until: until,
                                                  pageSize: min(30, max(1, limit)))
                    let queryURL = URL(string: "https://www.cninfo.com.cn/new/hisAnnouncement/query")!
                    requests += 1
                    let response = try await client.postForm(queryURL, fields: fields, headers: [
                        "User-Agent": "Mozilla/5.0",
                        "Origin": "https://www.cninfo.com.cn",
                        "Referer": "https://www.cninfo.com.cn/new/disclosure/stock?stockCode=\(code)",
                        "X-Requested-With": "XMLHttpRequest"
                    ])
                    rawResponses.append(RawEventResponse(sourceID: identifier, url: queryURL,
                        contentType: response.contentType, data: response.data))
                    let root = try EventParsing.object(response.data)
                    guard let rows = root["announcements"] as? [[String: Any]] else {
                        throw EventNetworkError.provider("CNINFO response did not contain announcements")
                    }
                    successfulRequests += 1
                    candidateRows += rows.count
                    let parsed = rows.compactMap { Self.parseAnnouncement($0, fetchedAt: until) }
                    validRows += parsed.count
                    events.append(contentsOf: parsed
                        .filter { ($0.publishedAt ?? .distantPast) >= since })
                } catch {
                    errors.append("\(code): \(error.localizedDescription)")
                }
            }
            let unique = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { old, new in
                old.fetchedAt >= new.fetchedAt ? old : new
            }).values.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
                .prefix(max(1, limit))
            let result = Array(unique)
            let unsupported = stockCodes.filter { !Self.isVerifiedSZSECode($0) }
            let notes = [
                "Public CNINFO web endpoint; no completeness/freshness SLA was verified.",
                unsupported.isEmpty ? nil : "Unsupported exchange codes (no verified mapping): \(unsupported.joined(separator: ", ")).",
                szseCodes.count < stockCodes.filter(Self.isVerifiedSZSECode).count ? "Capped at 10 SZSE codes per refresh." : nil
            ].compactMap { $0 }
            return EventFetchBatch(events: result, status: EventSourceStatus(sourceID: identifier,
                latestPublishedAt: result.compactMap(\.publishedAt).max(), requestedCount: stockCodes.count,
                returnedCount: result.count, requestCount: requests, successfulRequestCount: successfulRequests,
                candidateRecordCount: candidateRows, validRecordCount: validRows,
                error: errors.isEmpty ? nil : errors.joined(separator: "; "), note: notes.joined(separator: " ")),
                rawResponses: rawResponses)
        } catch {
            return disclosureFailure(sourceID: identifier, requested: stockCodes.count,
                requests: max(1, requests), error: error,
                note: "CNINFO announcements are queried only for selected SZSE codes with observed public orgId mappings.")
        }
    }

    public static func parseStockMap(_ data: Data) throws -> [String: String] {
        guard let value = try? JSONSerialization.jsonObject(with: data) else { throw EventNetworkError.invalidJSON }
        let rows: [[String: Any]]
        if let array = value as? [[String: Any]] { rows = array }
        else if let object = value as? [String: Any], let array = object["data"] as? [[String: Any]] { rows = array }
        else if let object = value as? [String: Any], let array = object["stockList"] as? [[String: Any]] { rows = array }
        else { throw EventNetworkError.provider("CNINFO stock map shape was not recognized") }
        var result: [String: String] = [:]
        for row in rows {
            guard let code = EventParsing.string(row["code"]),
                  let orgID = EventParsing.string(row["orgId"]), isVerifiedSZSECode(code) else { continue }
            result[code] = orgID
        }
        return result
    }

    public static func parseAnnouncement(_ row: [String: Any], fetchedAt: Date = Date()) -> MarketEvent? {
        guard let title = EventParsing.string(row["announcementTitle"]),
              let code = EventParsing.string(row["secCode"]) else { return nil }
        let timestamp = EventParsing.date(row["announcementTime"])
        let relativePath = EventParsing.string(row["adjunctUrl"])
        let attachmentURL: String? = {
            guard let relativePath else { return nil }
            if relativePath.hasPrefix("https://") || relativePath.hasPrefix("http://") { return relativePath }
            return URL(string: "https://static.cninfo.com.cn/\(relativePath.trimmingCharacters(in: CharacterSet(charactersIn: "/")))")?.absoluteString
        }()
        return MarketEvent(kind: .announcement, sourceID: "cninfo",
            sourceItemID: EventParsing.string(row["announcementId"]) ?? EventParsing.string(row["id"]),
            title: title, body: EventParsing.string(row["announcementContent"]), url: attachmentURL,
            publishedAt: timestamp, fetchedAt: fetchedAt, providerTimestampVerified: timestamp != nil,
            priority: 5, impactScope: .stock,
            sectors: [], stockCodes: [code])
    }

    private static func queryFields(code: String, orgID: String, since: Date, until: Date, pageSize: Int) -> [(String, String)] {
        [
            ("pageNum", "1"), ("pageSize", String(pageSize)), ("column", "szse"),
            ("tabName", "fulltext"), ("plate", "sz"), ("stock", "\(code),\(orgID)"),
            ("searchkey", ""), ("secid", ""), ("category", ""),
            ("trade", ""), ("seDate", "\(dateString(since))~\(dateString(until))"),
            ("sortName", ""), ("sortType", ""), ("isHLtitle", "true")
        ]
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func isVerifiedSZSECode(_ code: String) -> Bool {
        ["000", "001", "002", "003", "300", "301"].contains(where: { code.hasPrefix($0) })
    }
}

public struct EastmoneyDragonTigerSource: StockAwareMarketEventSource {
    public let identifier = "eastmoney_lhb"
    private let client: PublicEventHTTPClient

    public init(budget: RequestBudget) { client = PublicEventHTTPClient(budget: budget) }

    public func fetch(since: Date, limit: Int, stockCodes: [String]) async -> EventFetchBatch {
        let codes = Array(Set(stockCodes.filter { $0.range(of: "^[0-9]{6}$", options: .regularExpression) != nil })).sorted().prefix(10)
        guard !codes.isEmpty else {
            return EventFetchBatch(events: [], status: EventSourceStatus(sourceID: identifier,
                requestedCount: stockCodes.count, returnedCount: 0, requestCount: 0,
                note: "Queries only the current watchlist; no full-market crawl is performed."))
        }
        var events: [MarketEvent] = []
        var errors: [String] = []
        var requests = 0
        var successfulRequests = 0
        var candidateRows = 0
        var validRows = 0
        var rawResponses: [RawEventResponse] = []
        for code in codes {
            do {
                let url = try Self.queryURL(code: code, pageSize: min(20, max(1, limit)))
                requests += 1
                let response = try await client.get(url, headers: [
                    "User-Agent": "Mozilla/5.0", "Referer": "https://data.eastmoney.com/stock/lhb.html"
                ])
                rawResponses.append(RawEventResponse(sourceID: identifier, url: url,
                    contentType: response.contentType, data: response.data))
                let root = try EventParsing.object(response.data)
                if let success = root["success"] as? Bool, !success {
                    throw EventNetworkError.provider("Eastmoney LHB application error \(EventParsing.string(root["code"]) ?? "unknown"): \(EventParsing.string(root["message"]) ?? "")")
                }
                guard let result = root["result"] as? [String: Any],
                      let rows = result["data"] as? [[String: Any]] else {
                    throw EventNetworkError.provider("Eastmoney LHB response did not contain result.data")
                }
                successfulRequests += 1
                candidateRows += rows.count
                let parsed = rows.compactMap { Self.parseSummaryRow($0) }
                validRows += parsed.count
                events.append(contentsOf: parsed
                    .filter { ($0.publishedAt ?? .distantPast) >= since })
            } catch {
                errors.append("\(code): \(error.localizedDescription)")
            }
        }
        let result = Array(Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { old, new in
            old.fetchedAt >= new.fetchedAt ? old : new
        }).values.sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }.prefix(max(1, limit)))
        let notes = [
            "Public but undocumented Eastmoney billboard data; TRADE_DATE is a date, not an observed intraday publication time.",
            codes.count < stockCodes.count ? "Capped at 10 watchlist codes per refresh." : nil,
            "Summary report only; seat BUY/SELL detail is not fetched in this slice."
        ].compactMap { $0 }
        return EventFetchBatch(events: result, status: EventSourceStatus(sourceID: identifier,
            latestPublishedAt: result.filter(\.providerTimestampVerified).compactMap(\.publishedAt).max(),
            requestedCount: stockCodes.count,
            returnedCount: result.count, requestCount: requests, successfulRequestCount: successfulRequests,
            candidateRecordCount: candidateRows, validRecordCount: validRows,
            error: errors.isEmpty ? nil : errors.joined(separator: "; "), note: notes.joined(separator: " ")),
            rawResponses: rawResponses)
    }

    public static func queryURL(code: String, pageSize: Int = 20) throws -> URL {
        var components = URLComponents(string: "https://datacenter-web.eastmoney.com/api/data/v1/get")
        components?.queryItems = [
            URLQueryItem(name: "reportName", value: "RPT_DAILYBILLBOARD_DETAILSNEW"),
            URLQueryItem(name: "columns", value: "ALL"),
            URLQueryItem(name: "filter", value: "(SECURITY_CODE=\"\(code)\")"),
            URLQueryItem(name: "pageNumber", value: "1"),
            URLQueryItem(name: "pageSize", value: String(max(1, min(pageSize, 20)))),
            URLQueryItem(name: "sortTypes", value: "-1"),
            URLQueryItem(name: "sortColumns", value: "TRADE_DATE"),
            URLQueryItem(name: "source", value: "WEB"),
            URLQueryItem(name: "client", value: "WEB")
        ]
        guard let url = components?.url else { throw EventNetworkError.invalidURL }
        return url
    }

    public static func parseSummaryRow(_ row: [String: Any], fetchedAt: Date = Date()) -> MarketEvent? {
        guard let code = EventParsing.string(row["SECURITY_CODE"]),
              let tradeDate = EventParsing.date(row["TRADE_DATE"]) else { return nil }
        let name = EventParsing.string(row["SECURITY_NAME_ABBR"]) ?? code
        let explanation = EventParsing.string(row["EXPLANATION"]) ?? EventParsing.string(row["EXPLAIN"])
        var details: [String] = []
        if let explanation { details.append("上榜原因：\(explanation)") }
        if let value = EventParsing.string(row["CHANGE_RATE"]) { details.append("涨跌幅：\(value)") }
        if let value = EventParsing.string(row["BILLBOARD_BUY_AMT"]) { details.append("买入额：\(value)") }
        if let value = EventParsing.string(row["BILLBOARD_SELL_AMT"]) { details.append("卖出额：\(value)") }
        if let value = EventParsing.string(row["BILLBOARD_NET_AMT"]) { details.append("净买入：\(value)") }
        let itemID = EventParsing.string(row["TRADE_ID"]) ?? "\(code)-\(Int(tradeDate.timeIntervalSince1970 / 86_400))"
        return MarketEvent(kind: .dragonTiger, sourceID: "eastmoney_lhb", sourceItemID: itemID,
            title: "龙虎榜：\(name)（\(code)）上榜", body: details.isEmpty ? nil : details.joined(separator: "；"),
            url: "https://data.eastmoney.com/stock/lhb.html", publishedAt: tradeDate,
            fetchedAt: fetchedAt, providerTimestampVerified: false, priority: 3,
            impactScope: .stock, stockCodes: [code])
    }
}

private func disclosureFailure(sourceID: String, requested: Int, requests: Int, error: Error,
                               note: String) -> EventFetchBatch {
    EventFetchBatch(events: [], status: EventSourceStatus(sourceID: sourceID,
        requestedCount: requested, returnedCount: 0, requestCount: requests,
        error: error.localizedDescription, note: note))
}

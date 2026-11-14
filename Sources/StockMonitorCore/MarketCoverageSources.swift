import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum DailyLimitAvailability: String, Codable, Sendable, Equatable {
    case computed
    case unavailable
}

public struct DailyLimitResult: Codable, Sendable, Equatable {
    public let availability: DailyLimitAvailability
    public let pair: LimitPair?
    public let note: String
    public let percentage: Double?

    public init(availability: DailyLimitAvailability, pair: LimitPair? = nil,
                note: String, percentage: Double? = nil) {
        self.availability = availability
        self.pair = pair
        self.note = note
        self.percentage = percentage
    }
}

public protocol DailyLimitSource: Sendable {
    func limit(for quote: Quote, listingSessionIndex: Int?) -> DailyLimitResult
}

/// Formula estimate only: it is not an authoritative exchange-provided limit price.
public struct LocalDailyLimitSource: DailyLimitSource {
    public init() {}

    public func limit(for quote: Quote, listingSessionIndex: Int? = nil) -> DailyLimitResult {
        limit(code: quote.code, name: quote.name, previousClose: quote.previousClose,
              listingSessionIndex: listingSessionIndex)
    }

    public func limit(code: String, name: String = "", previousClose: Double,
                      listingSessionIndex: Int? = nil) -> DailyLimitResult {
        guard previousClose.isFinite, previousClose > 0 else {
            return .init(availability: .unavailable, note: "previousClose 无效，无法计算 0.01 元 tick 限价")
        }
        if let index = listingSessionIndex, index < 1 {
            return .init(availability: .unavailable, note: "listingSessionIndex 无效，不能判断 IPO 无涨跌幅阶段")
        }
        if name.contains("退市") || name.contains("退") || name.contains("整理") {
            return .init(availability: .unavailable,
                         note: "证券简称提示退市/整理状态，但退市首日状态未接入；限价未知")
        }
        let isBeijingCode = code.hasPrefix("8") || code.hasPrefix("4") || code.hasPrefix("92")
        if let index = listingSessionIndex,
           (isBeijingCode ? index == 1 : (1...5).contains(index)) {
            let sessionRule = isBeijingCode ? "北交所上市首日" : "上市后前 5 个交易日"
            return .init(availability: .unavailable,
                         note: "显式标注为\(sessionRule)第\(index)日：无价格涨跌幅限制，无 LimitPair")
        }

        // Prefixes identify the venue heuristically. Rates are verified against
        // exchange/regulator rules effective in 2026; this does not establish an
        // IPO/delisting status, which must be supplied separately.
        let percentage: Double
        let board: String
        if code.hasPrefix("688") {
            percentage = 0.20; board = "科创板"
        } else if code.hasPrefix("300") || code.hasPrefix("301") {
            percentage = 0.20; board = "创业板"
        } else if isBeijingCode {
            percentage = 0.30; board = "北交所（代码前缀识别）"
        } else if code.hasPrefix("6") {
            percentage = 0.10; board = name.localizedCaseInsensitiveContains("ST") ?
                "沪市主板风险警示（2026规则10%）" : "沪市主板"
        } else if code.hasPrefix("0") {
            percentage = 0.10; board = name.localizedCaseInsensitiveContains("ST") ?
                "深市主板风险警示（2026规则10%）" : "深市主板"
        } else {
            return .init(availability: .unavailable,
                         note: "未知沪/深/京板块，不能安全推断涨跌幅限制")
        }
        let roundedUp = roundedTick(previousClose * (1 + percentage))
        let roundedDown = roundedTick(previousClose * (1 - percentage))
        // Exchange rules specify 0.01 CNY ticks and at least one tick of
        // movement when percentage rounding would otherwise equal the close.
        let up = roundedUp - previousClose < 0.01
            ? roundedTick(previousClose + 0.01) : roundedUp
        let down = previousClose - roundedDown < 0.01
            ? max(0.01, roundedTick(previousClose - 0.01)) : roundedDown
        let assumption = listingSessionIndex == nil ? "；ipoIndex 未知，假设非上市前5日" : ""
        return .init(availability: .computed, pair: LimitPair(up: up, down: down),
                     note: "按\(board)\(Int(percentage * 100))%规则、0.01元 tick 四舍五入计算；公式估算，非行情源权威限价\(assumption)",
                     percentage: percentage)
    }

    private func roundedTick(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}

public struct EastmoneyScanQuote: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }
    public let code: String
    public let name: String
    public let market: Int?
    public let price: Double?
    public let changePercent: Double?
    public let change: Double?
    public let volume: Double?
    public let amount: Double?
    public let turnover: Double?
    public let pe: Double?
    public let volumeRatio: Double?
    public let totalMarketValue: Double?
    public let mainNetFlow: Double?
    public let providerTimestamp: Date?
    public let raw: [String: Double]
}

/// Distribution over returned scan rows only. `changePercent` and all summary
/// values use percentage points (for example, 2.5 means +2.5%), not fractions.
public struct MarketChangeBucket: Codable, Sendable, Equatable, Identifiable {
    public let id: Int
    public let label: String
    public let count: Int

    public init(id: Int, label: String, count: Int) {
        self.id = id
        self.label = label
        self.count = count
    }
}

public struct MarketScanDistribution: Codable, Sendable, Equatable {
    public let sampleCount: Int
    public let meanPercentPoints: Double
    public let medianPercentPoints: Double
    public let buckets: [MarketChangeBucket]

    private static let bucketLabels = ["<−5%", "[−5%,−3%)", "[−3%,−1%)", "[−1%,0%)", "0%", "(0%,1%]", "(1%,3%]", "(3%,5%)", "≥5%"]

    public static func summarize(quotes: [EastmoneyScanQuote]) -> MarketScanDistribution? {
        let values = quotes.compactMap(\.changePercent).filter(\.isFinite)
        guard !values.isEmpty else { return nil }

        var counts = Array(repeating: 0, count: bucketLabels.count)
        for value in values {
            let index: Int
            if value < -5 { index = 0 }
            else if value < -3 { index = 1 }
            else if value < -1 { index = 2 }
            else if value < 0 { index = 3 }
            else if value == 0 { index = 4 }
            else if value <= 1 { index = 5 }
            else if value <= 3 { index = 6 }
            else if value < 5 { index = 7 }
            else { index = 8 }
            counts[index] += 1
        }

        let sorted = values.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? sorted[middle - 1] / 2 + sorted[middle] / 2
            : sorted[middle]
        let mean = values.reduce(0.0) { $0 + $1 / Double(values.count) }
        return MarketScanDistribution(sampleCount: values.count,
            meanPercentPoints: mean, medianPercentPoints: median,
            buckets: bucketLabels.enumerated().map { MarketChangeBucket(id: $0.offset, label: $0.element, count: counts[$0.offset]) })
    }

    private init(sampleCount: Int, meanPercentPoints: Double,
                 medianPercentPoints: Double, buckets: [MarketChangeBucket]) {
        self.sampleCount = sampleCount
        self.meanPercentPoints = meanPercentPoints
        self.medianPercentPoints = medianPercentPoints
        self.buckets = buckets
    }
}

public struct MarketScanSummary: Codable, Sendable, Equatable {
    public let up: Int
    public let flat: Int
    public let down: Int
    public let amount: Double?
    public let mainNetFlow: Double?
    public let limitUp: Int?
    public let limitDown: Int?
    public let brokenSeal: Int?
    public let reportedTotalCount: Int?
    public let uniqueReturnedCount: Int
    public let sampleCoverageFraction: Double?
    public let coverageComplete: Bool
    public let coverageIncomplete: Bool
    public let truncated: Bool
    public let invalidRowCount: Int
    public let duplicateRowCount: Int
    public let changeBuckets: [MarketChangeBucket]?
    public let unavailableReason: String

    public init(up: Int, flat: Int, down: Int, amount: Double?, mainNetFlow: Double?,
                limitUp: Int?, limitDown: Int?, brokenSeal: Int?,
                reportedTotalCount: Int? = nil, uniqueReturnedCount: Int? = nil,
                sampleCoverageFraction: Double? = nil, coverageComplete: Bool = false,
                coverageIncomplete: Bool = true, truncated: Bool = false,
                invalidRowCount: Int = 0, duplicateRowCount: Int = 0,
                changeBuckets: [MarketChangeBucket]? = nil, unavailableReason: String) {
        self.up = up
        self.flat = flat
        self.down = down
        self.amount = amount
        self.mainNetFlow = mainNetFlow
        self.limitUp = limitUp
        self.limitDown = limitDown
        self.brokenSeal = brokenSeal
        self.reportedTotalCount = reportedTotalCount
        self.uniqueReturnedCount = uniqueReturnedCount ?? (up + flat + down)
        self.sampleCoverageFraction = sampleCoverageFraction
        self.coverageComplete = coverageComplete
        self.coverageIncomplete = coverageIncomplete
        self.truncated = truncated
        self.invalidRowCount = invalidRowCount
        self.duplicateRowCount = duplicateRowCount
        self.changeBuckets = changeBuckets
        self.unavailableReason = unavailableReason
    }
}

public struct EastmoneyMarketScanResult: Sendable, Equatable {
    public let quotes: [EastmoneyScanQuote]
    public let topByPercent: [EastmoneyScanQuote]
    public let summary: MarketScanSummary
    public let status: SourceStatus
    public let reportedTotalCount: Int?
    public let uniqueReturnedCount: Int
    public let coverageFraction: Double?
    public let coverageComplete: Bool
    public let coverageIncomplete: Bool
    public let truncated: Bool
    public let invalidRowCount: Int
    public let duplicateRowCount: Int
    public let rawRowCount: Int
}

public struct EastmoneyMarketScanSource: Sendable {
    public static let aShareFS = "m:1+t:2,m:1+t:23,m:0+t:6,m:0+t:80,m:0+t:81"
    public let session: URLSession
    public let budget: RequestBudget
    public let maximumPages: Int
    public let maximumSecurities: Int
    private let baseURL: URL
    private let responseCache: ConditionalHTTPResponseCache

    public init(session: URLSession = .shared, budget: RequestBudget = .standard(),
                maximumPages: Int = 60, maximumSecurities: Int = 6_000,
                baseURL: URL = URL(string: "https://push2.eastmoney.com/api/qt/clist/get")!,
                responseCache: ConditionalHTTPResponseCache = .shared) {
        self.session = session; self.budget = budget
        self.maximumPages = max(1, min(100, maximumPages)); self.maximumSecurities = max(1, min(6_000, maximumSecurities))
        self.baseURL = baseURL
        self.responseCache = responseCache
    }

    public func fetch(page: Int = 1, pageSize: Int = 100, topN: Int = 10) async throws -> EastmoneyMarketScanResult {
        let safePage = min(max(1, page), maximumPages)
        // Eastmoney's market-scan contract is requested at its maximum page size.
        // Keep pageSize source-compatible, but do not let callers reduce coverage.
        let count = 100
        try await budget.acquire(host: baseURL.host ?? "push2.eastmoney.com")
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            .init(name: "pn", value: String(safePage)), .init(name: "pz", value: String(count)),
            .init(name: "po", value: "1"), .init(name: "np", value: "1"),
            .init(name: "fltt", value: "2"), .init(name: "invt", value: "2"),
            .init(name: "fs", value: Self.aShareFS),
            .init(name: "fields", value: "f2,f3,f4,f5,f6,f8,f9,f10,f12,f13,f14,f17,f18,f20,f21,f62,f116,f124")
        ]
        guard let url = components?.url else { throw QuoteSourceError.invalidURL }
        var request = URLRequest(url: url); request.timeoutInterval = 8
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("StockMonitor/6.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
        let fetchedAt = Date()
        let (data, http, _) = try await responseCache.fetch(request, using: session)
        try QuoteSourceError.validateHTTPResponse(http, data: data)
        guard let first = data.first, first != 60, first != 91,
              let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any], let rows = payload["diff"] as? [[String: Any]] else {
            throw QuoteSourceError.malformedResponse
        }
        let reportedTotalCount = (payload["total"] as? Int).flatMap { (0...1_000_000).contains($0) ? $0 : nil }
        let quotes = rows.compactMap(Self.parse)
        let invalidRowCount = rows.count - quotes.count
        let sorted = quotes.sorted { ($0.changePercent ?? -.greatestFiniteMagnitude) > ($1.changePercent ?? -.greatestFiniteMagnitude) }
        let validChanges = quotes.compactMap(\.changePercent)
        let amounts = quotes.compactMap(\.amount)
        let flows = quotes.compactMap(\.mainNetFlow)
        let distribution = MarketScanDistribution.summarize(quotes: quotes)
        let coverageFraction = Self.coverageFraction(returnedCount: quotes.count, reportedTotalCount: reportedTotalCount)
        let summary = MarketScanSummary(up: validChanges.filter { $0 > 0 }.count,
            flat: validChanges.filter { $0 == 0 }.count, down: validChanges.filter { $0 < 0 }.count,
            amount: amounts.isEmpty ? nil : amounts.reduce(0, +),
            mainNetFlow: flows.isEmpty ? nil : flows.reduce(0, +), limitUp: nil, limitDown: nil,
            brokenSeal: nil, reportedTotalCount: reportedTotalCount,
            uniqueReturnedCount: quotes.count, sampleCoverageFraction: coverageFraction,
            coverageComplete: false, coverageIncomplete: true, invalidRowCount: invalidRowCount,
            changeBuckets: distribution?.buckets,
            unavailableReason: "clist/get 当前未发现可验证的限价字段；涨停、跌停、炸板家数保持 nil，不能估成精确计数")
        let provider = quotes.compactMap(\.providerTimestamp).max()
        let status = SourceStatus(sourceID: "eastmoney.clist", fetchedAt: fetchedAt,
            providerTimestamp: provider, requestedCount: count, returnedCount: quotes.count,
            requestCount: 1, note: "非官方 public clist/get；f62 原样作为 mainNetFlow，单位未独立验证；fltt=2 下 f3/f8/f9/f10 按实录缩放除以100；缺失/零市值保持 nil")
        return EastmoneyMarketScanResult(quotes: quotes, topByPercent: Array(sorted.prefix(max(0, topN))),
                                         summary: summary, status: status,
                                         reportedTotalCount: reportedTotalCount,
                                         uniqueReturnedCount: quotes.count, coverageFraction: coverageFraction,
                                         coverageComplete: false, coverageIncomplete: true, truncated: false,
                                         invalidRowCount: invalidRowCount, duplicateRowCount: 0,
                                         rawRowCount: rows.count)
    }

    /// Scans a bounded number of pages for market breadth. Partial page failure is
    /// returned as partial data with an error status; it is never labeled complete.
    public func fetchUniverse(pageSize: Int = 100, topN: Int = 20) async throws -> EastmoneyMarketScanResult {
        // Use Eastmoney's maximum page size so requested pages are derived from its total.
        let safeSize = 100
        let maximumPagesForLimit = min(maximumPages, max(1, (maximumSecurities + safeSize - 1) / safeSize))
        // Without a provider-reported total, one page is the safe bound: do not
        // blindly walk the entire cap when the pagination denominator is unknown.
        var pagesToRequest = 1
        var allQuotes: [EastmoneyScanQuote] = []
        var requestCount = 0
        var lastError: String?
        var notes: [String] = []
        var reportedTotalCount: Int?
        var reportedTotalChanged = false
        var invalidRowCount = 0
        var duplicateRowCount = 0
        var truncated = false
        var page = 1
        while page <= pagesToRequest {
            if Task.isCancelled { break }
            do {
                let result = try await fetch(page: page, pageSize: safeSize, topN: topN)
                requestCount += result.status.requestCount
                allQuotes.append(contentsOf: result.quotes)
                invalidRowCount += result.invalidRowCount
                if let note = result.status.note { notes.append(note) }
                if let reported = result.reportedTotalCount {
                    if let previous = reportedTotalCount, previous != reported {
                        reportedTotalChanged = true
                    } else if reportedTotalCount == nil {
                        reportedTotalCount = reported
                        truncated = reported > maximumSecurities
                        let desiredRows = min(reported, maximumSecurities)
                        pagesToRequest = min(maximumPagesForLimit,
                            max(1, (desiredRows + safeSize - 1) / safeSize))
                    }
                }
                if result.rawRowCount == 0 {
                    if let total = reportedTotalCount, allQuotes.count < total { truncated = true }
                    break
                }
                if page == pagesToRequest, let total = reportedTotalCount,
                   total > page * safeSize { truncated = true }
                page += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
        if Task.isCancelled { throw CancellationError() }
        var latestByCode: [String: EastmoneyScanQuote] = [:]
        var seenCodes = Set<String>()
        var cappedUniqueRowCount = 0
        for quote in allQuotes {
            guard seenCodes.insert(quote.code).inserted else {
                duplicateRowCount += 1
                continue
            }
            guard latestByCode.count < maximumSecurities else {
                cappedUniqueRowCount += 1
                continue
            }
            latestByCode[quote.code] = quote
        }
        if cappedUniqueRowCount > 0 { truncated = true }
        let sampleQuotes = latestByCode.values.sorted { $0.code < $1.code }
        let changes = sampleQuotes.compactMap(\.changePercent)
        let amounts = sampleQuotes.compactMap(\.amount)
        let flows = sampleQuotes.compactMap(\.mainNetFlow)
        let distribution = MarketScanDistribution.summarize(quotes: sampleQuotes)
        let coverageFraction = Self.coverageFraction(returnedCount: sampleQuotes.count,
                                                      reportedTotalCount: reportedTotalCount)
        let totalCoverageIncomplete = reportedTotalCount.map { sampleQuotes.count != $0 } ?? true
        let partial = lastError != nil || reportedTotalChanged || totalCoverageIncomplete ||
            truncated || invalidRowCount > 0 || duplicateRowCount > 0 || cappedUniqueRowCount > 0
        let coverageComplete = !partial && reportedTotalCount != nil
        let summary = MarketScanSummary(up: changes.filter { $0 > 0 }.count,
            flat: changes.filter { $0 == 0 }.count, down: changes.filter { $0 < 0 }.count,
            amount: amounts.isEmpty ? nil : amounts.reduce(0, +),
            mainNetFlow: flows.isEmpty ? nil : flows.reduce(0, +),
            limitUp: nil, limitDown: nil, brokenSeal: nil,
            reportedTotalCount: reportedTotalCount, uniqueReturnedCount: sampleQuotes.count,
            sampleCoverageFraction: coverageFraction, coverageComplete: coverageComplete,
            coverageIncomplete: !coverageComplete, truncated: truncated,
            invalidRowCount: invalidRowCount, duplicateRowCount: duplicateRowCount,
            changeBuckets: distribution?.buckets,
            unavailableReason: "Limit-up/down/broken-seal counts are unavailable from verified fields; breadth covers only returned clist rows.\(partial ? " Scan is partial; do not interpret these counts as full-market totals." : "")")
        let sorted = sampleQuotes.sorted { ($0.changePercent ?? -.greatestFiniteMagnitude) > ($1.changePercent ?? -.greatestFiniteMagnitude) }
        let status = SourceStatus(sourceID: "eastmoney.clist", fetchedAt: Date(),
            providerTimestamp: allQuotes.compactMap(\.providerTimestamp).max(),
            requestedCount: min(maximumSecurities, requestCount * safeSize),
            returnedCount: sampleQuotes.count, requestCount: requestCount,
            error: lastError,
            note: "Bounded multi-page unofficial scan (pz=100; max \(maximumSecurities) securities, \(maximumPages) pages); \(Self.coverageNote(returnedCount: sampleQuotes.count, total: reportedTotalCount))\(reportedTotalChanged ? " Provider total changed during scan." : "")\(invalidRowCount > 0 ? " Invalid rows=\(invalidRowCount)." : "")\(duplicateRowCount > 0 ? " Duplicate rows=\(duplicateRowCount)." : "") \(notes.first ?? "")\(partial ? " Partial/incomplete coverage." : " Complete coverage.")")
        return EastmoneyMarketScanResult(quotes: sampleQuotes,
            topByPercent: Array(sorted.prefix(max(0, topN))), summary: summary, status: status,
            reportedTotalCount: reportedTotalCount, uniqueReturnedCount: sampleQuotes.count,
            coverageFraction: coverageFraction, coverageComplete: coverageComplete,
            coverageIncomplete: !coverageComplete, truncated: truncated,
            invalidRowCount: invalidRowCount, duplicateRowCount: duplicateRowCount,
            rawRowCount: allQuotes.count + invalidRowCount)
    }

    private static func coverageFraction(returnedCount: Int, reportedTotalCount: Int?) -> Double? {
        guard let reportedTotalCount, reportedTotalCount > 0,
              returnedCount >= 0, returnedCount <= reportedTotalCount else { return nil }
        return Double(returnedCount) / Double(reportedTotalCount)
    }

    private static func coverageNote(returnedCount: Int, total: Int?) -> String {
        guard let total, total > 0 else { return "Provider total unavailable; coverage denominator is unknown." }
        guard returnedCount <= total else { return "Returned unique rows exceed provider total; coverage ratio is unknown." }
        return String(format: "Provider-reported total=%d; returned unique rows=%d (%.1f%%).",
                      total, returnedCount, Double(returnedCount) / Double(total) * 100)
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber else { return nil }
        let d = n.doubleValue; return d.isFinite ? d : nil
    }
    private static func parse(_ row: [String: Any]) -> EastmoneyScanQuote? {
        guard let code = row["f12"] as? String, !code.isEmpty, let name = row["f14"] as? String else { return nil }
        let keys = ["f2","f3","f4","f5","f6","f8","f9","f10","f17","f18","f20","f21","f62","f116"]
        var raw: [String: Double] = [:]; for key in keys { if let value = number(row[key]) { raw[key] = value } }
        let timestamp = number(row["f124"]).map { Date(timeIntervalSince1970: $0) }
        let marketValue = [number(row["f20"]), number(row["f116"])].compactMap { $0 }.first { $0 > 0 }
        return EastmoneyScanQuote(code: code, name: name, market: number(row["f13"]).map(Int.init),
            price: number(row["f2"]), changePercent: number(row["f3"]).map { $0 / 100 }, change: number(row["f4"]),
            volume: number(row["f5"]), amount: number(row["f6"]), turnover: number(row["f8"]).map { $0 / 100 },
            pe: number(row["f9"]).map { $0 / 100 }, volumeRatio: number(row["f10"]).map { $0 / 100 }, totalMarketValue: marketValue,
            mainNetFlow: number(row["f62"]), providerTimestamp: timestamp, raw: raw)
    }
}

public enum LimitUpPoolAvailability: String, Codable, Sendable, Equatable { case known, unknown }
public struct LimitUpPoolOutcome: Codable, Sendable, Equatable {
    public let availability: LimitUpPoolAvailability
    public let rawCount: Int?
    public let boards: Int?
    public let openTimes: Int?
    public let fdAmount: Double?
    public let note: String
    public let status: SourceStatus
}

public struct EastmoneyLimitUpPoolSource: Sendable {
    public let session: URLSession
    public let budget: RequestBudget
    private let baseURL: URL
    public static let requestUT = "7eea3edcaed734bea9cbfc24409ed989"
    public init(session: URLSession = .shared, budget: RequestBudget = .standard(),
                baseURL: URL = URL(string: "https://push2ex.eastmoney.com/getTopicZTPool")!) {
        self.session = session; self.budget = budget; self.baseURL = baseURL
    }
    public func fetch(date: String) async throws -> LimitUpPoolOutcome {
        guard date.range(of: "^[0-9]{8}$", options: .regularExpression) != nil else { throw QuoteSourceError.invalidURL }
        try await budget.acquire(host: baseURL.host ?? "push2ex.eastmoney.com")
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        c?.queryItems = [
            .init(name: "cb", value: ""), .init(name: "ut", value: Self.requestUT),
            .init(name: "dpt", value: "wzttz"), .init(name: "Pageindex", value: "0"),
            .init(name: "pagesize", value: "100"), .init(name: "sort", value: "fbt:asc"),
            .init(name: "date", value: date),
            .init(name: "_", value: String(Int(Date().timeIntervalSince1970 * 1_000)))
        ]
        guard let url = c?.url else { throw QuoteSourceError.invalidURL }
        var request = URLRequest(url: url); request.timeoutInterval = 8
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("StockMonitor/6.0", forHTTPHeaderField: "User-Agent")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        let fetched = Date(); let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw QuoteSourceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1) }
        guard data.first != 60, let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuoteSourceError.malformedResponse }
        guard let payload = root["data"] as? [String: Any] else {
            let status = SourceStatus(sourceID: "eastmoney.limitUpPool", fetchedAt: fetched, requestedCount: 1, returnedCount: 0, requestCount: 1, note: "data 缺失；涨停池状态 unknown")
            return .init(availability: .unknown, rawCount: nil, boards: nil, openTimes: nil, fdAmount: nil, note: "响应无可验证 data，所有池字段 unknown", status: status)
        }
        guard let pool = payload["pool"] as? [[String: Any]] else {
            let status = SourceStatus(sourceID: "eastmoney.limitUpPool", fetchedAt: fetched, requestedCount: 1, returnedCount: 0, requestCount: 1, note: "observed data:null 或无 pool；不将其误计为 0")
            return .init(availability: .unknown, rawCount: nil, boards: nil, openTimes: nil, fdAmount: nil, note: "data:null/无 pool => unknown；row schema 未验证", status: status)
        }
        let status = SourceStatus(sourceID: "eastmoney.limitUpPool", fetchedAt: fetched, requestedCount: 1, returnedCount: pool.count, requestCount: 1, note: "仅报告非空 pool 原始行数；row 字段 schema 未验证，不猜映射")
        return .init(availability: .known, rawCount: pool.count, boards: nil, openTimes: nil, fdAmount: nil, note: "raw pool count；boards/open_times/fd_amount unavailable/unverified", status: status)
    }
}

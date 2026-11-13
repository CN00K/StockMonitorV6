import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct DailyHistoryBatch: Sendable {
    public let bars: [DailyBar]
    public let status: SourceStatus
    public let skippedCodes: [String]
    public let warnings: [String]

    public init(bars: [DailyBar], status: SourceStatus, skippedCodes: [String] = [], warnings: [String] = []) {
        self.bars = bars
        self.status = status
        self.skippedCodes = skippedCodes
        self.warnings = warnings
    }
}

public protocol DailyHistoryProviding: Sendable {
    func fetchDailyHistory(codes: [String], from: Date, to: Date) async -> DailyHistoryBatch
}

/// Best-effort Eastmoney daily K-line source, queried only for caller-supplied codes.
/// The endpoint is undocumented; HTTP 200 with missing/empty klines is treated as failure.
public struct EastmoneyDailyHistorySource: DailyHistoryProviding, @unchecked Sendable {
    public let identifier = "eastmoney-kline-daily"
    private let session: URLSession
    private let budget: RequestBudget
    private let maximumSymbols: Int

    public init(session: URLSession = .shared, budget: RequestBudget = .standard(), maximumSymbols: Int = 50) {
        self.session = session
        self.budget = budget
        self.maximumSymbols = min(50, max(1, maximumSymbols))
    }

    public func fetchDailyHistory(codes: [String], from: Date, to: Date) async -> DailyHistoryBatch {
        let requested = Array(Set(codes)).sorted()
        let selected = Array(requested.prefix(maximumSymbols))
        var skipped = Array(requested.dropFirst(selected.count))
        var allBars: [DailyBar] = []
        var requests = 0
        var succeeded = 0
        var errors: [String] = []
        var fetchedAt = Date()

        for (offset, code) in selected.enumerated() {
            guard !Task.isCancelled else { break }
            guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
                skipped.append(code)
                continue
            }
            do {
                try await budget.acquire(host: "push2his.eastmoney.com")
                requests += 1
                let payload = try await fetch(code: code, from: from, to: to)
                let data = payload["data"] as? [String: Any]
                let name = data?["name"] as? String ?? code
                let rows = data?["klines"] as? [String] ?? []
                let responseTime = Date()
                fetchedAt = responseTime
                let parsed = Self.parseKLineRows(rows, code: code, name: name, fetchedAt: responseTime)
                    .filter { $0.tradeDate >= Self.chinaDay(from) && $0.tradeDate <= Self.chinaDay(to) }
                guard !parsed.isEmpty else {
                    errors.append("\(code): empty or invalid daily K-line response")
                    continue
                }
                succeeded += 1
                allBars.append(contentsOf: parsed)
            } catch {
                errors.append("\(code): \(Self.safeErrorDescription(error))")
                if let budgetError = error as? RequestBudgetError,
                   case .sessionLimitExceeded(_, _) = budgetError {
                    skipped.append(contentsOf: selected.dropFirst(offset))
                    break
                }
                if Task.isCancelled { break }
            }
        }

        allBars.sort { $0.tradeDate == $1.tradeDate ? $0.code < $1.code : $0.tradeDate < $1.tradeDate }
        let error = succeeded == 0 && !selected.isEmpty
            ? errors.first ?? "No usable daily-history response" : nil
        let status = SourceStatus(sourceID: identifier, fetchedAt: fetchedAt,
            requestedCount: requested.count, returnedCount: allBars.count,
            requestCount: requests, error: error,
            note: "\(succeeded)/\(requests) serial per-code requests; unadjusted (fqt=0); 50-code/session host budget shared with minute history\(errors.isEmpty ? "" : "; \(errors.count) per-code failures")")
        return DailyHistoryBatch(bars: allBars, status: status, skippedCodes: Array(Set(skipped)).sorted(), warnings: errors)
    }

    public static func parseKLineRows(_ rows: [String], code: String, name: String,
                                      fetchedAt: Date = Date()) -> [DailyBar] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        var bars: [DailyBar] = []
        for row in rows {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, let date = formatter.date(from: fields[0]),
                  let open = Double(fields[1]), let close = Double(fields[2]),
                  let high = Double(fields[3]), let low = Double(fields[4]),
                  let volumeValue = Double(fields[5]), volumeValue.isFinite, volumeValue >= 0,
                  volumeValue < Double(Int64.max), open.isFinite, close.isFinite,
                  high.isFinite, low.isFinite, open > 0, close > 0, high >= low else { continue }
            let amount = Double(fields[6]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let turnover = fields.count > 10
                ? Double(fields[10]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
            bars.append(DailyBar(code: code, name: name, tradeDate: date,
                open: open, high: high, low: low, close: close, volume: Int64(volumeValue),
                amount: amount, turnoverRate: turnover, sourceID: "eastmoney-kline-daily",
                fetchedAt: fetchedAt, priceAdjustment: "none"))
        }
        return Dictionary(bars.map { ($0.tradeDate, $0) }, uniquingKeysWith: { old, new in
            old.fetchedAt >= new.fetchedAt ? old : new
        }).values.sorted { $0.tradeDate < $1.tradeDate }
    }

    private func fetch(code: String, from: Date, to: Date) async throws -> [String: Any] {
        var components = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/kline/get")
        components?.queryItems = [
            URLQueryItem(name: "secid", value: EastmoneyQuoteSource.securityID(for: code)),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6,f7,f8,f9,f10,f11,f12,f13"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"),
            URLQueryItem(name: "beg", value: Self.dayString(from)),
            URLQueryItem(name: "end", value: Self.dayString(to)),
            URLQueryItem(name: "rtntype", value: "6"),
            URLQueryItem(name: "klt", value: "101"),
            URLQueryItem(name: "fqt", value: "0")
        ]
        guard let url = components?.url else { throw QuoteSourceError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw DailyHistoryError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard data.count <= 5 * 1_024 * 1_024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DailyHistoryError.malformedResponse
        }
        return object
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketClock.timeZone
        formatter.dateFormat = "yyyyMMdd"
        return formatter.string(from: date)
    }

    private static func chinaDay(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketClock.timeZone
        return calendar.startOfDay(for: date)
    }

    private static func safeErrorDescription(_ error: Error) -> String {
        if let error = error as? DailyHistoryError { return error.localizedDescription }
        if error is CancellationError { return "cancelled" }
        return "network request failed"
    }
}

public enum DailyHistoryError: Error, LocalizedError {
    case httpStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let code): return "HTTP status \(code)"
        case .malformedResponse: return "Malformed or oversized response"
        }
    }
}

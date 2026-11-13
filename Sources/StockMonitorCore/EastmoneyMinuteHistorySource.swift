import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public Eastmoney trends2 adapter. The endpoint accepts one security ID per
/// request and returns a rolling window; it cannot guarantee complete event replay.
public struct EastmoneyMinuteHistorySource: HistoricalReconcileSource, @unchecked Sendable {
    public let identifier = "eastmoney-trends2"
    private let session: URLSession
    private let budget: RequestBudget
    private let maximumSymbolsPerOpen: Int

    public init(session: URLSession = .shared, budget: RequestBudget = .standard(), maximumSymbolsPerOpen: Int = 50) {
        self.session = session
        self.budget = budget
        self.maximumSymbolsPerOpen = min(50, max(1, maximumSymbolsPerOpen))
    }

    public func reconcile(codes: [String], afterByCode: [String: Date]) async -> ReconcileResult {
        let allCodes = Array(Set(codes)).sorted()
        let selected = Array(allCodes.prefix(maximumSymbolsPerOpen))
        var skipped = Array(allCodes.dropFirst(selected.count))
        var recovered: [MinuteBar] = []
        var fetchedAt = Date()
        var requestCount = 0
        var successfulRequests = 0
        var warnings: [String] = ["Minute bars are sampled 1-minute data, not a replay of every trade or intraminute event.",
                                  "Eastmoney trends2 is queried one security per request; its rolling window is not a guaranteed recovery period."]
        var providerTimestamps: [Date] = []
        var codesWithBars = Set<String>()
        var errors: [String] = []

        for code in selected {
            if Task.isCancelled { break }
            guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
                skipped.append(code)
                continue
            }
            do {
                try await budget.acquire(host: "push2his.eastmoney.com")
            } catch {
                skipped.append(code)
                errors.append(error.localizedDescription)
                if Task.isCancelled { break }
                continue
            }
            requestCount += 1
            let requestTime = Date()
            do {
                let payload = try await fetchTrends(code: code)
                fetchedAt = Date()
                successfulRequests += 1
                let data = payload["data"] as? [String: Any]
                let name = data?["name"] as? String ?? code
                let rows = data?["trends"] as? [String] ?? []
                let fullBars = Self.parseTrendRows(rows, code: code, name: name, fetchedAt: fetchedAt)
                guard !fullBars.isEmpty else {
                    errors.append("\(code): no minute rows returned")
                    continue
                }
                providerTimestamps.append(contentsOf: fullBars.map(\.timestamp))
                let cursor = afterByCode[code]
                let newBars = fullBars.filter { bar in
                    guard let cursor else { return true }
                    return bar.timestamp > cursor
                }
                if let cursor, let earliest = fullBars.first?.timestamp, earliest.timeIntervalSince(cursor) > 60 {
                    warnings.append("\(code): returned window begins after the saved cursor; an unrecovered gap may remain.")
                }
                if !newBars.isEmpty {
                    codesWithBars.insert(code)
                    recovered.append(contentsOf: newBars)
                }
            } catch {
                errors.append("\(code): \(error.localizedDescription)")
                if Task.isCancelled { break }
            }
            if Date().timeIntervalSince(requestTime) > 10 {
                warnings.append("Some history requests were slow; the foreground session remains subject to iOS suspension.")
            }
        }
        if !Array(allCodes.prefix(maximumSymbolsPerOpen)).isEmpty && !skipped.isEmpty {
            warnings.append("\(skipped.count) watchlist code(s) were skipped because of the 50-symbol or request-budget cap.")
        }
        if !errors.isEmpty { warnings.append("Some symbols had no usable history; see source status for error details.") }
        recovered.sort {
            if $0.timestamp == $1.timestamp { return $0.code < $1.code }
            return $0.timestamp < $1.timestamp
        }
        let status = SourceStatus(sourceID: identifier, fetchedAt: fetchedAt,
            providerTimestamp: providerTimestamps.max(), requestedCount: allCodes.count,
            returnedCount: recovered.count, requestCount: requestCount,
            error: successfulRequests == 0 && !selected.isEmpty ? errors.first ?? "No history response" : nil,
            note: "\(successfulRequests)/\(requestCount) per-security requests succeeded; rolling ndays=5; 50-symbol cap")
        if !errors.isEmpty { warnings.append(contentsOf: errors.prefix(5)) }
        let report = ReconcileReport(sourceID: identifier, requestedCodes: allCodes,
            reconciledCodes: codesWithBars.sorted(), skippedCodes: Array(Set(skipped)).sorted(),
            barCount: recovered.count, earliestBar: recovered.first?.timestamp,
            latestBar: recovered.last?.timestamp, warnings: Array(Set(warnings)).sorted(),
            requestCount: requestCount)
        return ReconcileResult(bars: recovered, report: report, status: status)
    }

    static func parseTrendRows(_ rows: [String], code: String, name: String, fetchedAt: Date) -> [MinuteBar] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        var raw: [(timestamp: Date, open: Double, close: Double, high: Double, low: Double, volume: Int64, amount: Double?)] = []
        for row in rows {
            let fields = row.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 7, let timestamp = formatter.date(from: fields[0]),
                  let open = Double(fields[1]), let close = Double(fields[2]),
                  let high = Double(fields[3]), let low = Double(fields[4]),
                  let volumeDouble = Double(fields[5]), volumeDouble >= 0,
                  volumeDouble < Double(Int64.max), open.isFinite, close.isFinite,
                  high.isFinite, low.isFinite else { continue }
            let amount = Double(fields[6]).flatMap { $0.isFinite ? $0 : nil }
            raw.append((timestamp, open, close, high, low, Int64(volumeDouble), amount))
        }
        raw.sort { $0.timestamp < $1.timestamp }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = MarketClock.timeZone
        dayFormatter.dateFormat = "yyyy-MM-dd"
        let grouped = Dictionary(grouping: raw, by: { dayFormatter.string(from: $0.timestamp) })
        var previousDailyClose: Double?
        var result: [MinuteBar] = []
        for day in grouped.keys.sorted() {
            let dayRows = (grouped[day] ?? []).sorted { $0.timestamp < $1.timestamp }
            for row in dayRows {
                result.append(MinuteBar(code: code, name: name, timestamp: row.timestamp,
                    open: row.open, close: row.close, high: row.high, low: row.low,
                    volume: row.volume, amount: row.amount, previousClose: previousDailyClose,
                    sourceID: "eastmoney-trends2", fetchedAt: fetchedAt))
            }
            previousDailyClose = dayRows.last?.close ?? previousDailyClose
        }
        return result
    }

    private func fetchTrends(code: String) async throws -> [String: Any] {
        var components = URLComponents(string: "https://push2his.eastmoney.com/api/qt/stock/trends2/get")
        components?.queryItems = [
            URLQueryItem(name: "secid", value: EastmoneyQuoteSource.securityID(for: code)),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f4,f5,f6"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"),
            URLQueryItem(name: "ndays", value: "5"),
            URLQueryItem(name: "iscr", value: "0"),
            URLQueryItem(name: "iscca", value: "0")
        ]
        guard let url = components?.url else { throw QuoteSourceError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw QuoteSourceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QuoteSourceError.malformedResponse
        }
        return object
    }
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One minute of vendor-reported flow data. Eastmoney's public endpoint is
/// undocumented; values are preserved as returned (nominally CNY) and must not
/// be treated as exchange-certified order flow.
public struct MoneyFlowMinute: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(code):\(timestamp.timeIntervalSince1970)" }
    public let code: String
    public let timestamp: Date
    public let mainNetInflow: Double
    public let smallNetInflow: Double
    public let mediumNetInflow: Double
    public let largeNetInflow: Double
    public let superLargeNetInflow: Double
    public let sourceID: String

    public init(code: String, timestamp: Date, mainNetInflow: Double,
                smallNetInflow: Double, mediumNetInflow: Double,
                largeNetInflow: Double, superLargeNetInflow: Double,
                sourceID: String = "eastmoney_fflow") {
        self.code = code
        self.timestamp = timestamp
        self.mainNetInflow = mainNetInflow
        self.smallNetInflow = smallNetInflow
        self.mediumNetInflow = mediumNetInflow
        self.largeNetInflow = largeNetInflow
        self.superLargeNetInflow = superLargeNetInflow
        self.sourceID = sourceID
    }
}

public struct MoneyFlowBatch: Sendable {
    public let minutes: [MoneyFlowMinute]
    public let status: SourceStatus

    public init(minutes: [MoneyFlowMinute], status: SourceStatus) {
        self.minutes = minutes
        self.status = status
    }
}

public protocol MoneyFlowProviding: Sendable {
    func fetch(codes: [String]) async -> MoneyFlowBatch
}

/// Fetches the latest intraday rows from the observed Eastmoney fflow endpoint.
/// It deliberately does not infer values from f44/f45 or request user credentials.
public struct EastmoneyMoneyFlowSource: MoneyFlowProviding, @unchecked Sendable {
    public let identifier = "eastmoney_fflow"
    private let session: URLSession
    private let budget: RequestBudget
    private let maximumSymbols: Int
    private let responseCache: ConditionalHTTPResponseCache

    public init(session: URLSession = .shared, budget: RequestBudget = .standard(), maximumSymbols: Int = 50, responseCache: ConditionalHTTPResponseCache = .shared) {
        self.session = session
        self.budget = budget
        self.maximumSymbols = min(50, max(1, maximumSymbols))
        self.responseCache = responseCache
    }

    public func fetch(codes: [String]) async -> MoneyFlowBatch {
        let requested = Array(Set(codes.filter(Self.isSixDigitCode))).sorted()
        let selected = Array(requested.prefix(maximumSymbols))
        var rows: [MoneyFlowMinute] = []
        var errors: [String] = []
        var requests = 0
        for code in selected {
            if Task.isCancelled { break }
            do {
                try await budget.acquire(host: "push2.eastmoney.com")
                requests += 1
                guard let url = Self.requestURL(code: code) else { throw QuoteSourceError.invalidURL }
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
                request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
                request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
                request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
                let (data, response, _) = try await responseCache.fetch(request, using: session)
                try QuoteSourceError.validateHTTPResponse(response, data: data)
                guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let payload = root["data"] as? [String: Any],
                      let raw = payload["klines"] as? [String] else { throw QuoteSourceError.malformedResponse }
                rows.append(contentsOf: Self.parse(raw, code: code))
            } catch {
                errors.append("\(code): \(error.localizedDescription)")
            }
        }
        let latest = Dictionary(grouping: rows, by: \.code).compactMapValues { $0.max { $0.timestamp < $1.timestamp } }
        let status = SourceStatus(sourceID: identifier, fetchedAt: Date(),
            providerTimestamp: rows.map(\.timestamp).max(), requestedCount: requested.count,
            returnedCount: latest.count, requestCount: requests,
            error: errors.isEmpty ? nil : errors.joined(separator: "; "),
            note: "Unofficial minute-flow endpoint; f51=time, f52=main, f53=small, f54=medium, f55=large, f56=super-large. Units and completeness are not exchange-certified.\(selected.count < requested.count ? " Capped at \(maximumSymbols) symbols." : "")")
        return MoneyFlowBatch(minutes: latest.values.sorted { $0.code < $1.code }, status: status)
    }

    public static func requestURL(code: String) -> URL? {
        guard isSixDigitCode(code) else { return nil }
        var components = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/fflow/kline/get")
        components?.queryItems = [
            URLQueryItem(name: "secid", value: securityID(for: code)),
            URLQueryItem(name: "lmt", value: "0"),
            URLQueryItem(name: "klt", value: "1"),
            URLQueryItem(name: "fields1", value: "f1,f2,f3,f7"),
            URLQueryItem(name: "fields2", value: "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61,f62,f63")
        ]
        return components?.url
    }

    /// Parses the six actually observed columns; trailing/unobserved fields are ignored.
    public static func parse(_ klines: [String], code: String) -> [MoneyFlowMinute] {
        guard isSixDigitCode(code) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return klines.compactMap { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, let timestamp = formatter.date(from: fields[0]),
                  let main = finite(fields[1]), let small = finite(fields[2]),
                  let medium = finite(fields[3]), let large = finite(fields[4]),
                  let superLarge = finite(fields[5]) else { return nil }
            return MoneyFlowMinute(code: code, timestamp: timestamp,
                mainNetInflow: main, smallNetInflow: small, mediumNetInflow: medium,
                largeNetInflow: large, superLargeNetInflow: superLarge)
        }.sorted { $0.timestamp < $1.timestamp }
    }

    private static func securityID(for code: String) -> String {
        let prefix = (code.hasPrefix("6") || code.hasPrefix("9")) ? "1" : "0"
        return "\(prefix).\(code)"
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }

    private static func finite(_ value: String) -> Double? {
        guard let number = Double(value), number.isFinite else { return nil }
        return number
    }
}

/// Optional decorator for callers that explicitly enable money-flow collection.
/// It makes at most `maximumSymbols` additional per-code requests per foreground
/// refresh; callers that do not wrap their quote provider make no flow requests.
public struct MoneyFlowAugmentingMarketDataProvider: MarketDataProviding {
    private let quotes: any MarketDataProviding
    private let moneyFlow: any MoneyFlowProviding
    private let maximumSymbols: Int

    public init(quotes: any MarketDataProviding, moneyFlow: any MoneyFlowProviding,
                maximumSymbols: Int = 50) {
        self.quotes = quotes
        self.moneyFlow = moneyFlow
        self.maximumSymbols = min(50, max(1, maximumSymbols))
    }

    public func fetch(codes: [String], indices: [MarketIndex]) async -> MarketDataBatch {
        let batch = await quotes.fetch(codes: codes, indices: indices)
        let selected = Array(batch.quotes.map(\.code).sorted().prefix(maximumSymbols))
        guard !selected.isEmpty else { return batch }
        let flows = await moneyFlow.fetch(codes: selected)
        let byCode = Dictionary(uniqueKeysWithValues: flows.minutes.map { ($0.code, $0) })
        let augmented = batch.quotes.map { quote -> Quote in
            guard let flow = byCode[quote.code] else { return quote }
            return Quote(code: quote.code, name: quote.name, timestamp: quote.timestamp,
                price: quote.price, previousClose: quote.previousClose, open: quote.open,
                high: quote.high, low: quote.low, volume: quote.volume, amount: quote.amount,
                turnoverRate: quote.turnoverRate, volumeRatio: quote.volumeRatio, dynamicPE: quote.dynamicPE,
                totalMarketValue: quote.totalMarketValue, floatMarketValue: quote.floatMarketValue,
                mainNetInflow: flow.mainNetInflow, largeNetInflow: flow.largeNetInflow,
                superLargeNetInflow: flow.superLargeNetInflow, moneyFlowTimestamp: flow.timestamp,
                moneyFlowSourceID: flow.sourceID, sourceID: quote.sourceID,
                retrievedAt: quote.retrievedAt, timestampIsProvider: quote.timestampIsProvider, kind: quote.kind)
        }
        let capped = batch.quotes.count > selected.count
        let flowStatus = capped ? SourceStatus(sourceID: flows.status.sourceID, fetchedAt: flows.status.fetchedAt,
            providerTimestamp: flows.status.providerTimestamp, requestedCount: batch.quotes.count,
            returnedCount: flows.status.returnedCount, requestCount: flows.status.requestCount,
            error: flows.status.error, note: (flows.status.note ?? "") + " Remaining symbols were not queried by the decorator cap.") : flows.status
        return MarketDataBatch(quotes: augmented, indexQuotes: batch.indexQuotes,
            sourceStatuses: batch.sourceStatuses + [flowStatus], missingCodes: batch.missingCodes,
            missingIndexCodes: batch.missingIndexCodes, suspectCodes: batch.suspectCodes,
            marketCoverage: batch.marketCoverage)
    }
}

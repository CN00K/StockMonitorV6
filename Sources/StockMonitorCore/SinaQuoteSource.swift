import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Public, unauthenticated endpoint. Its response contract and rate limits are
/// not guaranteed by Sina; strict parsing and registry fallback are intentional.
public struct SinaQuoteSource: MarketQuoteSource, @unchecked Sendable {
    public let identifier = "sina"
    private let session: URLSession
    private let budget: RequestBudget
    private let batchSize: Int

    public init(session: URLSession = .shared, budget: RequestBudget = .standard(), batchSize: Int = 50) {
        self.session = session
        self.budget = budget
        self.batchSize = min(50, max(1, batchSize))
    }

    public func fetchMarketData(codes: [String], indices: [MarketIndex]) async throws -> ProviderQuoteBatch {
        let stocks = Array(Set(codes)).sorted().filter(isSixDigitCode)
        let all = stocks.map { ($0, stockSymbol($0), false) }
            + indices.map { ($0.code, $0.sinaSymbol, true) }
        let indexSymbols = Set(indices.map(\.sinaSymbol))
        guard !all.isEmpty else {
            return ProviderQuoteBatch(quotes: [], indexQuotes: [], status: SourceStatus(sourceID: identifier,
                fetchedAt: Date(), requestedCount: 0, returnedCount: 0, requestCount: 0))
        }
        var quotes: [Quote] = []
        var requestCount = 0
        for start in stride(from: 0, to: all.count, by: batchSize) {
            let end = min(start + batchSize, all.count)
            let slice = all[start..<end]
            try await budget.acquire(host: "hq.sinajs.cn")
            requestCount += 1
            let symbols = slice.map { $0.1 }
            guard var components = URLComponents(string: "https://hq.sinajs.cn/list=\(symbols.joined(separator: ","))") else {
                throw QuoteSourceError.invalidURL
            }
            components.queryItems = [URLQueryItem(name: "rn", value: String(Int(Date().timeIntervalSince1970)))]
            guard let url = components.url else { throw QuoteSourceError.invalidURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("https://finance.sina.com.cn/", forHTTPHeaderField: "Referer")
            request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
            let retrievedAt = Date()
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw QuoteSourceError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
            }
            guard let text = QuoteTextDecoder.gbkOrUTF8(data) else {
                throw QuoteSourceError.malformedResponse
            }
            quotes.append(contentsOf: Self.parse(text, retrievedAt: retrievedAt, indexSymbols: indexSymbols))
        }
        let indexQuotes = quotes.filter { $0.kind == .index }
        let stockQuotes = quotes.filter { $0.kind == .stock }
        let status = SourceStatus(sourceID: identifier, fetchedAt: Date(),
            providerTimestamp: quotes.filter(\.timestampIsProvider).map(\.timestamp).max(),
            requestedCount: all.count, returnedCount: quotes.count, requestCount: requestCount,
            note: "Sina public text endpoint; provider contract/rate limit is not guaranteed")
        return ProviderQuoteBatch(quotes: stockQuotes, indexQuotes: indexQuotes, status: status)
    }

    static func parse(_ body: String, retrievedAt: Date = Date(), indexSymbols: Set<String> = []) -> [Quote] {
        body.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let marker = line.range(of: "=\""), line.hasSuffix("\";") else { return nil }
            let symbolPart = String(line[..<marker.lowerBound])
            guard let symbol = symbolPart.split(separator: "_").last else { return nil }
            let symbolText = String(symbol)
            guard symbolText.count >= 8 else { return nil }
            let code = String(symbolText.dropFirst(2))
            let payloadStart = marker.upperBound
            let payloadEnd = line.index(line.endIndex, offsetBy: -2)
            let fields = line[payloadStart..<payloadEnd].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 32,
                  let open = Double(fields[1]), let previous = Double(fields[2]),
                  let price = Double(fields[3]), let high = Double(fields[4]), let low = Double(fields[5]),
                  let volumeValue = Double(fields[8]), volumeValue.isFinite, volumeValue >= 0,
                  volumeValue < Double(Int64.max), let amount = Double(fields[9]) else { return nil }
            let dateText = fields[30] + " " + fields[31]
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = MarketClock.timeZone
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let providerTime = formatter.date(from: dateText)
            let timestamp = providerTime ?? retrievedAt
            return Quote(code: code, name: fields[0], timestamp: timestamp, price: price,
                previousClose: previous, open: open, high: high, low: low,
                volume: Int64(volumeValue), amount: amount, sourceID: "sina",
                retrievedAt: retrievedAt, timestampIsProvider: providerTime != nil,
                kind: indexSymbols.contains(symbolText) ? .index : .stock)
        }
    }

    private func stockSymbol(_ code: String) -> String {
        (code.hasPrefix("6") || code.hasPrefix("9") ? "sh" : "sz") + code
    }

    private func isSixDigitCode(_ code: String) -> Bool {
        code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }
}

public enum QuoteSourceError: Error, LocalizedError {
    case invalidURL
    case httpStatus(Int)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid quote source URL"
        case .httpStatus(let status): return "Quote source returned HTTP \(status)"
        case .malformedResponse: return "Quote source returned an unrecognized payload"
        }
    }
}

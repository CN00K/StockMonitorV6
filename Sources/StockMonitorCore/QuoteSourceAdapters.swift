import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Eastmoney's unauthenticated ulist endpoint, observed to return f2/f3/f4/f5/f6,
/// f12/f13/f14/f15/f16/f17/f18 and f124. It is not a contractual API.
public struct EastmoneyQuoteSource: MarketQuoteSource, @unchecked Sendable {
    public let identifier = "eastmoney"
    private let session: URLSession
    private let budget: RequestBudget
    private let batchSize: Int
    private let responseCache: ConditionalHTTPResponseCache

    public init(session: URLSession = .shared, budget: RequestBudget = .standard(), batchSize: Int = 50, responseCache: ConditionalHTTPResponseCache = .shared) {
        self.session = session
        self.budget = budget
        self.batchSize = min(50, max(1, batchSize))
        self.responseCache = responseCache
    }

    public func fetchMarketData(codes: [String], indices: [MarketIndex]) async throws -> ProviderQuoteBatch {
        let stocks = Array(Set(codes)).sorted().filter(isSixDigitCode)
        let indexBySecID = Dictionary(uniqueKeysWithValues: indices.map { ($0.eastmoneySecurityID, $0) })
        let stockSecIDs = stocks.map(Self.securityID(for:))
        let allIDs = (stockSecIDs + indices.map(\.eastmoneySecurityID)).uniqued()
        guard !allIDs.isEmpty else {
            return ProviderQuoteBatch(quotes: [], indexQuotes: [], status: SourceStatus(sourceID: identifier,
                fetchedAt: Date(), requestedCount: 0, returnedCount: 0, requestCount: 0))
        }
        var quotes: [Quote] = []
        var requests = 0
        for start in stride(from: 0, to: allIDs.count, by: batchSize) {
            let batch = Array(allIDs[start..<min(start + batchSize, allIDs.count)])
            try await budget.acquire(host: "push2.eastmoney.com")
            requests += 1
            var components = URLComponents(string: "https://push2.eastmoney.com/api/qt/ulist.np/get")
            components?.queryItems = [
                URLQueryItem(name: "fltt", value: "2"),
                URLQueryItem(name: "fields", value: "f2,f3,f4,f5,f6,f8,f9,f10,f12,f13,f14,f15,f16,f17,f18,f20,f21,f62,f124"),
                URLQueryItem(name: "secids", value: batch.joined(separator: ","))
            ]
            guard let url = components?.url else { throw QuoteSourceError.invalidURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
            request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
            let retrievedAt = Date()
            let (data, response, _) = try await responseCache.fetch(request, using: session)
            try QuoteSourceError.validateHTTPResponse(response, data: data)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["data"] as? [String: Any],
                  let rows = payload["diff"] as? [[String: Any]] else { throw QuoteSourceError.malformedResponse }
            quotes.append(contentsOf: Self.parse(rows, indicesBySecID: indexBySecID, retrievedAt: retrievedAt))
        }
        let stockQuotes = quotes.filter { $0.kind == .stock }
        let indexQuotes = quotes.filter { $0.kind == .index }
        let status = SourceStatus(sourceID: identifier, fetchedAt: Date(),
            providerTimestamp: quotes.filter(\.timestampIsProvider).map(\.timestamp).max(),
            requestedCount: stocks.count + indices.count, returnedCount: quotes.count, requestCount: requests,
            note: "Unofficial public endpoint; f124 is used as provider time when present")
        return ProviderQuoteBatch(quotes: stockQuotes, indexQuotes: indexQuotes, status: status)
    }

    static func parse(_ rows: [[String: Any]], indicesBySecID: [String: MarketIndex], retrievedAt: Date) -> [Quote] {
        rows.compactMap { row in
            guard let code = string(row["f12"]), code.count == 6,
                  let market = integer(row["f13"]), let price = number(row["f2"]),
                  let previous = number(row["f18"]), let open = number(row["f17"]),
                  let high = number(row["f15"]), let low = number(row["f16"]),
                  let volumeValue = number(row["f5"]), volumeValue >= 0,
                  volumeValue < Double(Int64.max) else { return nil }
            let secID = "\(market).\(code)"
            let index = indicesBySecID[secID]
            let resolvedCode = index?.code ?? code
            let name = string(row["f14"]) ?? index?.name ?? code
            let providerTime = number(row["f124"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }
            return Quote(code: resolvedCode, name: name, timestamp: providerTime ?? retrievedAt,
                price: price, previousClose: previous, open: open, high: high, low: low,
                volume: Int64(volumeValue), amount: number(row["f6"]),
                turnoverRate: number(row["f8"]), volumeRatio: number(row["f10"]),
                dynamicPE: number(row["f9"]), totalMarketValue: number(row["f20"]),
                floatMarketValue: number(row["f21"]), mainNetInflow: number(row["f62"]),
                moneyFlowTimestamp: number(row["f124"]).flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
                moneyFlowSourceID: number(row["f62"]) == nil ? nil : "eastmoney.clist.f62",
                sourceID: "eastmoney",
                retrievedAt: retrievedAt, timestampIsProvider: providerTime != nil,
                kind: index == nil ? .stock : .index)
        }
    }

    static func securityID(for code: String) -> String {
        "\((code.hasPrefix("6") || code.hasPrefix("9")) ? "1" : "0").\(code)"
    }

    private func isSixDigitCode(_ code: String) -> Bool {
        code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }
}

/// Tencent's public GBK text quote endpoint. Field positions are deliberately
/// limited to the stable core fields documented by community examples.
public struct TencentQuoteSource: MarketQuoteSource, @unchecked Sendable {
    public let identifier = "tencent"
    private let session: URLSession
    private let budget: RequestBudget
    private let batchSize: Int
    private let responseCache: ConditionalHTTPResponseCache

    public init(session: URLSession = .shared, budget: RequestBudget = .standard(), batchSize: Int = 50, responseCache: ConditionalHTTPResponseCache = .shared) {
        self.session = session
        self.budget = budget
        self.batchSize = min(50, max(1, batchSize))
        self.responseCache = responseCache
    }

    public func fetchMarketData(codes: [String], indices: [MarketIndex]) async throws -> ProviderQuoteBatch {
        let stocks = Array(Set(codes)).sorted().filter { $0.range(of: "^[0-9]{6}$", options: .regularExpression) != nil }
        var symbols: [String: (code: String, kind: QuoteKind, name: String?)] = [:]
        for code in stocks { symbols[Self.symbol(for: code)] = (code, .stock, nil) }
        for index in indices { symbols[index.tencentSymbol] = (index.code, .index, index.name) }
        let allSymbols = symbols.keys.sorted()
        guard !allSymbols.isEmpty else {
            return ProviderQuoteBatch(quotes: [], indexQuotes: [], status: SourceStatus(sourceID: identifier,
                fetchedAt: Date(), requestedCount: 0, returnedCount: 0, requestCount: 0))
        }
        var quotes: [Quote] = []
        var requests = 0
        for start in stride(from: 0, to: allSymbols.count, by: batchSize) {
            let batch = Array(allSymbols[start..<min(start + batchSize, allSymbols.count)])
            try await budget.acquire(host: "qt.gtimg.cn")
            requests += 1
            var components = URLComponents(string: "https://qt.gtimg.cn/")
            components?.path = "/q=\(batch.joined(separator: ","))"
            guard let url = components?.url else { throw QuoteSourceError.invalidURL }
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            request.setValue("https://gu.qq.com/", forHTTPHeaderField: "Referer")
            request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
            request.setValue("text/plain,*/*", forHTTPHeaderField: "Accept")
            request.setValue("gzip, deflate", forHTTPHeaderField: "Accept-Encoding")
            let retrievedAt = Date()
            let (data, response, _) = try await responseCache.fetch(request, using: session)
            try QuoteSourceError.validateHTTPResponse(response, data: data)
            guard let text = QuoteTextDecoder.gbkOrUTF8(data) else {
                throw QuoteSourceError.malformedResponse
            }
            try QuoteSourceError.validateHTTPResponse(response, data: data, decodedText: text)
            quotes.append(contentsOf: Self.parse(text, symbols: symbols, retrievedAt: retrievedAt))
        }
        let status = SourceStatus(sourceID: identifier, fetchedAt: Date(),
            providerTimestamp: quotes.filter(\.timestampIsProvider).map(\.timestamp).max(),
            requestedCount: stocks.count + indices.count, returnedCount: quotes.count, requestCount: requests,
            note: "Unofficial GBK text endpoint; amount is normalized from reported ten-thousand-yuan units")
        return ProviderQuoteBatch(quotes: quotes.filter { $0.kind == .stock },
                                  indexQuotes: quotes.filter { $0.kind == .index }, status: status)
    }

    static func parse(_ body: String, symbols: [String: (code: String, kind: QuoteKind, name: String?)],
                      retrievedAt: Date) -> [Quote] {
        body.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let line = String(rawLine)
            guard let marker = line.range(of: "=\""), line.hasSuffix("\";") else { return nil }
            let variable = String(line[..<marker.lowerBound])
            guard variable.hasPrefix("v_") else { return nil }
            let symbol = String(variable.dropFirst(2))
            guard let identity = symbols[symbol] else { return nil }
            let payloadStart = marker.upperBound
            let payloadEnd = line.index(line.endIndex, offsetBy: -2)
            let fields = line[payloadStart..<payloadEnd].split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 38,
                  let price = Double(fields[3]), let previous = Double(fields[4]),
                  let open = Double(fields[5]), let volume = Double(fields[36]),
                  let high = Double(fields[33]), let low = Double(fields[34]),
                  price.isFinite, previous.isFinite, volume >= 0, volume < Double(Int64.max) else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = MarketClock.timeZone
            formatter.dateFormat = "yyyyMMddHHmmss"
            let providerTime = formatter.date(from: fields[30])
            let amount = Double(fields[37]).flatMap { $0.isFinite ? $0 * 10_000 : nil }
            let turnoverRate = fields.indices.contains(38) ? Double(fields[38]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
            let dynamicPE = fields.indices.contains(39) ? Double(fields[39]).flatMap { $0.isFinite ? $0 : nil } : nil
            let totalMarketValue = fields.indices.contains(44) ? Double(fields[44]).flatMap { $0.isFinite && $0 > 0 ? $0 * 100_000_000 : nil } : nil
            let floatMarketValue = fields.indices.contains(45) ? Double(fields[45]).flatMap { $0.isFinite && $0 > 0 ? $0 * 100_000_000 : nil } : nil
            let volumeRatio = fields.indices.contains(49) ? Double(fields[49]).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } : nil
            return Quote(code: identity.code, name: identity.name ?? fields[1],
                timestamp: providerTime ?? retrievedAt, price: price, previousClose: previous,
                open: open, high: high, low: low, volume: Int64(volume), amount: amount,
                turnoverRate: turnoverRate, volumeRatio: volumeRatio, dynamicPE: dynamicPE,
                totalMarketValue: totalMarketValue, floatMarketValue: floatMarketValue,
                sourceID: "tencent", retrievedAt: retrievedAt,
                timestampIsProvider: providerTime != nil, kind: identity.kind)
        }
    }

    static func symbol(for code: String) -> String {
        (code.hasPrefix("6") || code.hasPrefix("9") ? "sh" : "sz") + code
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private func number(_ value: Any?) -> Double? {
    if let value = value as? NSNumber { return value.doubleValue.isFinite ? value.doubleValue : nil }
    if let value = value as? String { return Double(value).flatMap { $0.isFinite ? $0 : nil } }
    return nil
}

private func integer(_ value: Any?) -> Int? { number(value).map(Int.init) }
private func string(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    return String(describing: value)
}

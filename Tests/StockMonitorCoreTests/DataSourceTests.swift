import XCTest
@testable import StockMonitorCore

final class DataSourceTests: XCTestCase {
    func testEastmoneyParserPreservesProviderTimestampAndIndexKind() throws {
        let retrievedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let providerTime = Date(timeIntervalSince1970: 1_794_557_504)
        let stockRow: [String: Any] = [
            "f12": "600000", "f13": 1, "f14": "浦发银行", "f2": 10.40,
            "f3": 1.86, "f4": 0.19, "f5": 761573, "f6": 786507841.0,
            "f15": 10.44, "f16": 10.12, "f17": 10.19, "f18": 10.21,
            "f124": providerTime.timeIntervalSince1970
        ]
        let indexRow: [String: Any] = [
            "f12": "000001", "f13": 1, "f14": "上证指数", "f2": 3634.35,
            "f3": -0.59, "f4": -21.48, "f5": 472293657, "f6": 770614169984.0,
            "f15": 3669.44, "f16": 3623.84, "f17": 3658.72, "f18": 3655.83,
            "f124": providerTime.timeIntervalSince1970
        ]
        let parsed = EastmoneyQuoteSource.parse([stockRow, indexRow],
            indicesBySecID: ["1.000001": MarketIndex.core[0]], retrievedAt: retrievedAt)
        let stock = try XCTUnwrap(parsed.first { $0.code == "600000" })
        let index = try XCTUnwrap(parsed.first { $0.kind == .index })
        XCTAssertEqual(stock.sourceID, "eastmoney")
        XCTAssertEqual(stock.price, 10.40, accuracy: 1e-12)
        XCTAssertEqual(stock.timestamp, providerTime)
        XCTAssertEqual(stock.retrievedAt, retrievedAt)
        XCTAssertEqual(index.code, "000001")
        XCTAssertEqual(index.kind, .index)
    }

    func testTencentParserUsesCoreFieldsAndNormalizesAmount() throws {
        var fields = Array(repeating: "", count: 39)
        fields[0] = "1"; fields[1] = "浦发银行"; fields[2] = "600000"
        fields[3] = "10.40"; fields[4] = "10.21"; fields[5] = "10.19"
        fields[30] = "20261113161444"; fields[33] = "10.44"; fields[34] = "10.12"
        fields[36] = "761573"; fields[37] = "78650"
        let line = "v_sh600000=\"\(fields.joined(separator: "~"))\";"
        let parsed = TencentQuoteSource.parse(line,
            symbols: ["sh600000": (code: "600000", kind: .stock, name: nil)],
            retrievedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let quote = try XCTUnwrap(parsed.first)
        XCTAssertEqual(quote.price, 10.40, accuracy: 1e-12)
        XCTAssertEqual(quote.previousClose, 10.21, accuracy: 1e-12)
        XCTAssertEqual(quote.high, 10.44, accuracy: 1e-12)
        XCTAssertEqual(quote.low, 10.12, accuracy: 1e-12)
        XCTAssertEqual(quote.volume, 761_573)
        XCTAssertEqual(quote.amount ?? 0, 786_500_000, accuracy: 0.1)
        XCTAssertTrue(quote.timestampIsProvider)
        XCTAssertEqual(quote.sourceID, "tencent")
    }

    func testSinaParserCanDistinguishAnIndexFromSameNumericStockCode() throws {
        var fields = Array(repeating: "0", count: 32)
        fields[0] = "上证指数"; fields[1] = "3600"; fields[2] = "3590"
        fields[3] = "3610"; fields[4] = "3620"; fields[5] = "3580"
        fields[8] = "100"; fields[9] = "100000"
        fields[30] = "2026-11-13"; fields[31] = "15:00:00"
        let response = "var hq_str_sh000001=\"\(fields.joined(separator: ","))\";"
        let index = try XCTUnwrap(SinaQuoteSource.parse(response, indexSymbols: ["sh000001"]).first)
        XCTAssertEqual(index.code, "000001")
        XCTAssertEqual(index.kind, .index)
    }

    func testRegistryFallsBackSequentiallyWithoutOverwritingSuccessfulValues() async throws {
        let providerTime = Date(timeIntervalSince1970: 1_800_000_000)
        let fallback = StubQuoteSource(identifier: "eastmoney", shouldFail: false, quoteTime: providerTime)
        let primary = StubQuoteSource(identifier: "sina", shouldFail: true, quoteTime: providerTime)
        let registry = QuoteSourceRegistry(sources: [primary, fallback])
        let result = await registry.fetch(codes: ["600000"], indices: [])
        XCTAssertEqual(result.quotes.map(\.sourceID), ["eastmoney"])
        XCTAssertEqual(result.missingCodes, [])
        XCTAssertEqual(result.sourceStatuses.map(\.sourceID), ["sina", "eastmoney"])
        XCTAssertEqual(result.sourceStatuses.first?.requestCount, 1)
    }

    func testRequestBudgetEnforcesPerSessionCapAndCanReset() async throws {
        let budget = RequestBudget(policies: ["fixture": .init(requestsPerSecond: 100, maximumPerSession: 1)])
        try await budget.acquire(host: "fixture")
        do {
            try await budget.acquire(host: "fixture")
            XCTFail("Expected the per-session cap to stop the second request")
        } catch let error as RequestBudgetError {
            XCTAssertEqual(error, .sessionLimitExceeded(host: "fixture", limit: 1))
        }
        await budget.beginSession()
        try await budget.acquire(host: "fixture")
        let count = await budget.count(for: "fixture")
        XCTAssertEqual(count, 1)
    }

    func testTrendsParserBuildsDailyPreviousCloseContext() throws {
        let rows = [
            "2026-11-12 14:59,10.10,10.11,10.12,10.09,100,101100,0.2,0.1,0.01,0",
            "2026-11-12 15:00,10.11,10.12,10.13,10.10,200,202400,0.3,0.2,0.02,0",
            "2026-11-13 09:31,10.19,10.14,10.21,10.12,300,304200,0.8,-0.7,-0.07,0"
        ]
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let bars = EastmoneyMinuteHistorySource.parseTrendRows(rows, code: "600000", name: "浦发银行", fetchedAt: fetchedAt)
        XCTAssertEqual(bars.count, 3)
        XCTAssertNil(bars[0].previousClose)
        XCTAssertNil(bars[1].previousClose)
        XCTAssertEqual(bars[2].previousClose, 10.12)
        XCTAssertEqual(bars[2].close, 10.14, accuracy: 1e-12)
        XCTAssertEqual(bars[2].volume, 300)
    }

    func testRuleConditionCodableRoundTrip() throws {
        let rules = [
            WatchRule(id: "p", code: "600000", title: "price", detail: "above",
                      condition: .priceAtLeast(10.5), sustainedTicks: 2, cooldown: 30),
            WatchRule(id: "l", code: "600000", title: "limit", detail: "unknown",
                      condition: .limitUp(tolerance: 0.01))
        ]
        let data = try JSONEncoder().encode(rules)
        let decoded = try JSONDecoder().decode([WatchRule].self, from: data)
        XCTAssertEqual(decoded, rules)
    }
}

private struct StubQuoteSource: MarketQuoteSource {
    let identifier: String
    let shouldFail: Bool
    let quoteTime: Date

    func fetchMarketData(codes: [String], indices: [MarketIndex]) async throws -> ProviderQuoteBatch {
        if shouldFail { throw QuoteSourceError.malformedResponse }
        let quotes = codes.map { code in
            Quote(code: code, name: "fixture", timestamp: quoteTime, price: 10,
                previousClose: 9.9, open: 9.9, high: 10, low: 9.8, volume: 10,
                sourceID: identifier, retrievedAt: quoteTime, timestampIsProvider: true)
        }
        return ProviderQuoteBatch(quotes: quotes, indexQuotes: [], status: SourceStatus(
            sourceID: identifier, fetchedAt: quoteTime, providerTimestamp: quoteTime,
            requestedCount: codes.count + indices.count, returnedCount: quotes.count,
            requestCount: 1))
    }
}

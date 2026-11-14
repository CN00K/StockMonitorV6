import Foundation
import XCTest
@testable import StockMonitorCore

final class MarketCoverageAugmentingProviderTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testAugmentsQuoteBatchAndPreservesUnknownLimitCounts() async {
        let baseStatus = SourceStatus(sourceID: "quotes", fetchedAt: date,
            providerTimestamp: date, requestedCount: 1, returnedCount: 1, requestCount: 1)
        let baseQuote = Quote(code: "600000", name: "浦发银行", timestamp: date, price: 10,
            previousClose: 9.9, open: 9.9, high: 10, low: 9.8, volume: 100,
            sourceID: "fixture", retrievedAt: date)
        let base = FixedMarketProvider(batch: MarketDataBatch(quotes: [baseQuote], indexQuotes: [],
            sourceStatuses: [baseStatus]))
        let coverage = makeCoverage()
        let provider = MarketCoverageAugmentingProvider(quotes: base,
            coverage: FixedCoverageProvider(result: .success(coverage)))

        let batch = await provider.fetch(codes: ["600000"], indices: [])
        XCTAssertEqual(batch.quotes, [baseQuote])
        XCTAssertEqual(batch.marketCoverage, coverage)
        XCTAssertEqual(batch.sourceStatuses.map(\.sourceID), ["quotes", "eastmoney.clist"])
        XCTAssertNil(batch.marketCoverage?.summary.limitUp)
        XCTAssertNil(batch.marketCoverage?.summary.limitDown)
        XCTAssertNil(batch.marketCoverage?.summary.brokenSeal)
    }

    func testScanFailureDoesNotDropQuotesOrInventBreadth() async {
        let baseQuote = Quote(code: "600000", name: "浦发银行", timestamp: date, price: 10,
            previousClose: 9.9, open: 9.9, high: 10, low: 9.8, volume: 100,
            sourceID: "fixture", retrievedAt: date)
        let base = FixedMarketProvider(batch: MarketDataBatch(quotes: [baseQuote], indexQuotes: [], sourceStatuses: []))
        let provider = MarketCoverageAugmentingProvider(quotes: base,
            coverage: FixedCoverageProvider(result: .failure(TestFailure.expected)))

        let batch = await provider.fetch(codes: ["600000"], indices: [])
        XCTAssertEqual(batch.quotes, [baseQuote])
        XCTAssertNil(batch.marketCoverage)
        XCTAssertEqual(batch.sourceStatuses.last?.sourceID, "eastmoney.clist")
        XCTAssertNotNil(batch.sourceStatuses.last?.error)
    }

    private func makeCoverage() -> MarketCoverageSnapshot {
        let quote = EastmoneyScanQuote(code: "600000", name: "浦发银行", market: 1,
            price: 10, changePercent: 0.01, change: 0.1, volume: 1_000,
            amount: 10_000, turnover: nil, pe: nil, volumeRatio: nil,
            totalMarketValue: nil, mainNetFlow: nil, providerTimestamp: date, raw: [:])
        let summary = MarketScanSummary(up: 1, flat: 0, down: 0, amount: nil,
            mainNetFlow: nil, limitUp: nil, limitDown: nil, brokenSeal: nil,
            unavailableReason: "limit counts unavailable")
        let status = SourceStatus(sourceID: "eastmoney.clist", fetchedAt: date,
            providerTimestamp: date, requestedCount: 100, returnedCount: 1,
            requestCount: 1, note: "bounded fixture")
        return MarketCoverageSnapshot(summary: summary, topQuotes: [quote], status: status)
    }
}

private struct FixedMarketProvider: MarketDataProviding {
    let batch: MarketDataBatch
    func fetch(codes: [String], indices: [MarketIndex]) async -> MarketDataBatch { batch }
}

private struct FixedCoverageProvider: MarketCoverageProviding {
    let result: Result<MarketCoverageSnapshot, TestFailure>
    func fetchCoverage() async throws -> MarketCoverageSnapshot { try result.get() }
}

private enum TestFailure: Error { case expected }

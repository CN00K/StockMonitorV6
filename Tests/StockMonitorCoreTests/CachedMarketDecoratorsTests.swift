import Foundation
import XCTest
@testable import StockMonitorCore

final class CachedMarketDecoratorsTests: XCTestCase {
    func testMarketCoverageIsFetchedOncePerIntervalAndCacheHitDoesNotCountRequest() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = CountingMarketCoverageSource(timestamp: now)
        let cache = CachingMarketCoverageProvider(upstream: source,
            minimumRefreshInterval: 900, now: { now })

        let first = try await cache.fetchCoverage()
        let second = try await cache.fetchCoverage()
        let coverageCalls = await source.callCount
        XCTAssertEqual(coverageCalls, 1)
        XCTAssertEqual(first.status.requestCount, 1)
        XCTAssertEqual(second.status.requestCount, 0)
        XCTAssertEqual(second.status.fetchedAt, first.status.fetchedAt)
        XCTAssertTrue(second.status.note?.contains("Cached market scan") == true)
        XCTAssertEqual(second.summary.changeBuckets, first.summary.changeBuckets)
        XCTAssertEqual(second.summary.sampleCoverageFraction, first.summary.sampleCoverageFraction)
        XCTAssertEqual(second.sampleDistribution, first.sampleDistribution)
    }

    func testMoneyFlowIsCappedFreshAndReturnedFromCacheWithoutAdditionalRequests() async {
        let now = Date()
        let source = CountingMoneyFlowSource(timestamp: now)
        let cache = CachingMoneyFlowProvider(upstream: source, maximumSymbols: 2,
            minimumRefreshInterval: 600, maximumAge: 180, now: { now })
        let codes = ["600000", "000001", "600001"]

        let first = await cache.fetch(codes: codes)
        let second = await cache.fetch(codes: codes)
        let flowCalls = await source.callCount
        let requestedCodes = await source.lastRequestedCodes
        XCTAssertEqual(flowCalls, 1)
        XCTAssertEqual(requestedCodes.count, 2)
        XCTAssertEqual(first.status.requestCount, 1)
        XCTAssertEqual(first.minutes.count, 2)
        XCTAssertEqual(second.status.requestCount, 0)
        XCTAssertEqual(second.minutes.count, 2)
        XCTAssertFalse(second.minutes.contains(where: { $0.code == "600001" }))
        XCTAssertTrue(second.status.note?.contains("rate-limited locally") == true)
    }
}

private actor CountingMarketCoverageSource: MarketCoverageProviding {
    private(set) var callCount = 0
    private let timestamp: Date

    init(timestamp: Date) { self.timestamp = timestamp }

    func fetchCoverage() async throws -> MarketCoverageSnapshot {
        callCount += 1
        let quote = EastmoneyScanQuote(code: "600000", name: "fixture", market: nil,
            price: nil, changePercent: 1, change: nil, volume: nil, amount: nil,
            turnover: nil, pe: nil, volumeRatio: nil, totalMarketValue: nil,
            mainNetFlow: nil, providerTimestamp: timestamp, raw: [:])
        let distribution = MarketScanDistribution.summarize(quotes: [quote])
        let summary = MarketScanSummary(up: 2, flat: 0, down: 1, amount: nil,
            mainNetFlow: nil, limitUp: nil, limitDown: nil, brokenSeal: nil,
            reportedTotalCount: 1, sampleCoverageFraction: 1,
            changeBuckets: distribution?.buckets,
            unavailableReason: "Limit counts are unsupported and remain unknown.")
        let status = SourceStatus(sourceID: "fixture-market-scan", fetchedAt: timestamp,
            providerTimestamp: timestamp, requestedCount: 100, returnedCount: 3,
            requestCount: 1)
        return MarketCoverageSnapshot(summary: summary, topQuotes: [quote],
            sampleDistribution: distribution, status: status)
    }
}

private actor CountingMoneyFlowSource: MoneyFlowProviding {
    private(set) var callCount = 0
    private(set) var lastRequestedCodes: [String] = []
    private let timestamp: Date

    init(timestamp: Date) { self.timestamp = timestamp }

    func fetch(codes: [String]) async -> MoneyFlowBatch {
        callCount += 1
        lastRequestedCodes = codes
        let rows = codes.map { code in
            MoneyFlowMinute(code: code, timestamp: timestamp, mainNetInflow: 1,
                smallNetInflow: 0, mediumNetInflow: 0, largeNetInflow: 0,
                superLargeNetInflow: 0)
        }
        return MoneyFlowBatch(minutes: rows, status: SourceStatus(sourceID: "eastmoney_fflow",
            fetchedAt: timestamp, providerTimestamp: timestamp, requestedCount: codes.count,
            returnedCount: rows.count, requestCount: 1, note: "fixture"))
    }
}

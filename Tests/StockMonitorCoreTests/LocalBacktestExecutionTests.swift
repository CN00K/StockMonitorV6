import XCTest
@testable import StockMonitorCore

final class LocalBacktestExecutionTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2024, month: 1, day: day))!
    }
    private func bar(_ code: String, _ day: Int, _ close: Double) -> DailyBar {
        DailyBar(code: code, name: code, tradeDate: date(day), open: close, high: close,
                 low: close, close: close, volume: 10_000, amount: 100_000,
                 sourceID: "fixture", fetchedAt: date(day))
    }

    func testExecutionIsOptInAndGrossMetricsRemainIdentical() {
        var bars: [DailyBar] = []
        for day in 1...27 {
            bars += [bar("A", day, 100 + Double(day)), bar("B", day, 100), bar("C", day, 100 - Double(day))]
        }
        let gross = LocalBacktest.run(bars: bars, factor: .amount20, sampleSessions: 2)
        let config = LocalBacktestExecutionConfig(
            execution: AshareExecutionConfig(commissionRate: 0.001, minimumCommission: 5,
                                             stampDutyRate: 0.001, slippageRate: 0,
                                             tickSize: 0.01, lotSize: 100, side: .buy,
                                             initialCash: 100_000),
            quantityPerSignal: 100, topN: 1)
        let joined = LocalBacktest.run(bars: bars, factor: .amount20, sampleSessions: 2, execution: config)
        XCTAssertEqual(joined.gross.meanIC, gross.meanIC)
        XCTAssertEqual(joined.gross.icSeries, gross.icSeries)
        XCTAssertEqual(joined.gross.strata, gross.strata)
        XCTAssertEqual(joined.execution.validCount, 2)
        XCTAssertFalse(joined.netEquityCurve.isEmpty)
        XCTAssertTrue(joined.execution.events.contains { $0.filled && $0.commission > 0 })

        let distribution = LocalBacktestDistribution.build(report: joined, stratumIndex: 1)
        XCTAssertGreaterThan(distribution.summary.grossTradedNotional ?? 0, 0)
        XCTAssertEqual(distribution.summary.symbolTradeActivity?.reduce(0) { $0 + $1.fillCount }, joined.execution.validCount)
        XCTAssertNil(distribution.summary.turnover)
        XCTAssertNil(distribution.summary.holdingDurationSessions)
        XCTAssertNil(distribution.summary.symbolContributions)
        XCTAssertTrue(distribution.summary.unavailableReasons["turnover"]?.contains("portfolio NAV") == true)
    }

    func testMissingDataWarningsAreExplicitAndNoLimitIsInferred() {
        let bars = (1...24).flatMap { day in
            [bar("A", day, 100 + Double(day)), bar("B", day, 100), bar("C", day, 100 - Double(day))]
        }
        let config = LocalBacktestExecutionConfig(
            execution: AshareExecutionConfig(commissionRate: 0, minimumCommission: 0,
                                             stampDutyRate: 0, slippageRate: 0,
                                             tickSize: 0.01, lotSize: 100, side: .buy,
                                             initialCash: 10_000))
        let report = LocalBacktest.run(bars: bars, factor: .momentum5, sampleSessions: 2, execution: config)
        XCTAssertTrue(report.warnings.contains { $0.contains("Constituent membership data is missing") })
        XCTAssertTrue(report.warnings.contains { $0.contains("Corporate-action data is missing") })
        XCTAssertTrue(report.warnings.contains { $0.contains("Price-limit data is missing") })
        XCTAssertTrue(report.execution.warnings.contains { $0.contains("Only explicitly supplied price-limit pairs") })
    }

    func testLimitTouchStillProducesNoFillThroughBridge() {
        let bars = (1...24).flatMap { day in
            [bar("A", day, 100), bar("B", day, 100), bar("C", day, 100)]
        }
        let limit = AsharePriceLimit(code: "A", tradeDate: date(24), lower: 90, upper: 100)
        let config = LocalBacktestExecutionConfig(
            execution: AshareExecutionConfig(commissionRate: 0, minimumCommission: 0,
                                             stampDutyRate: 0, slippageRate: 0,
                                             tickSize: 0.01, lotSize: 100, side: .buy,
                                             initialCash: 10_000),
            quantityPerSignal: 100, topN: 1, priceLimits: [limit],
            dataAvailability: .init(priceLimits: true))
        let report = LocalBacktest.run(bars: bars, factor: .momentum5, sampleSessions: 1, execution: config)
        XCTAssertTrue(report.execution.events.contains { $0.reason == .priceLimitTouch })
        XCTAssertEqual(report.execution.events.filter(\.filled).count, 0)
    }
}

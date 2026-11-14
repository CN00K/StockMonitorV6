import XCTest
@testable import StockMonitorCore

final class LocalBacktestDistributionTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)
    private func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2024, month: 1, day: day))! }
    private func report() -> LocalBacktestReport {
        LocalBacktestReport(factor: .momentum5, sampleSessions: 3, strataCount: 1,
            strata: [LocalBacktestStratum(index: 1, sampleCount: 3, averageDailyReturn: nil, cumulativeReturn: nil,
                                           equityCurve: [100, 110, 99, 108], equityCurveDates: [date(1), date(2), date(3)])],
            icSeries: [], meanIC: nil, icStandardDeviation: nil, icir: nil, warnings: [])
    }
    private func bar(_ day: Int, _ close: Double, code: String = "BM") -> DailyBar {
        DailyBar(code: code, name: code, tradeDate: date(day), open: close, high: close, low: close, close: close, volume: 1)
    }

    func testExactDistributionAndStableOrdering() {
        let dataset = LocalBacktestDistribution.build(report: report())
        let expected = [0.1, -0.1, 108.0 / 99.0 - 1.0]
        XCTAssertEqual(dataset.dailyReturns.count, expected.count)
        for (actual, wanted) in zip(dataset.dailyReturns.map(\.value), expected) {
            XCTAssertEqual(actual, wanted, accuracy: 0.0000001)
        }
        XCTAssertEqual(dataset.dailyReturns.map(\.date), [date(1), date(2), date(3)])
        XCTAssertEqual(dataset.quantiles.minimum!, -0.1, accuracy: 0.0000001)
        XCTAssertEqual(dataset.quantiles.p50!, 108.0 / 99.0 - 1.0, accuracy: 0.0000001)
        XCTAssertEqual(dataset.quantiles.maximum!, 0.1, accuracy: 0.0000001)
        XCTAssertEqual(dataset.monthlyReturns.map(\.month), ["2024-01"])
    }

    func testMissingBenchmarkAndTradesAreUnknownWithReasons() {
        let dataset = LocalBacktestDistribution.build(report: report())
        XCTAssertTrue(dataset.dailyExcessReturns.isEmpty)
        XCTAssertNil(dataset.summary.benchmarkReturn)
        XCTAssertNil(dataset.summary.excessReturn)
        XCTAssertNil(dataset.summary.turnover)
        XCTAssertNil(dataset.summary.grossTradedNotional)
        XCTAssertNil(dataset.summary.symbolTradeActivity)
        XCTAssertNil(dataset.summary.holdingDurationSessions)
        XCTAssertNil(dataset.summary.symbolContributions)
        XCTAssertTrue(dataset.summary.unavailableReasons["benchmark"]!.contains("not explicitly supplied"))
        XCTAssertTrue(dataset.summary.unavailableReasons["turnover"]!.contains("portfolio NAV"))
    }

    func testExcessReturnRequiresCompleteDateAlignment() {
        let aligned = LocalBacktestDistribution.build(report: report(), benchmarkBars: [bar(0, 100), bar(1, 105), bar(2, 100), bar(3, 100)])
        XCTAssertEqual(aligned.summary.benchmarkReturn!, 0, accuracy: 0.0000001)
        XCTAssertEqual(aligned.summary.excessReturn!, 0.08, accuracy: 0.0000001)
        let expectedDailyExcess = [0.05, -0.1 + 5.0 / 105.0, 108.0 / 99.0 - 1]
        XCTAssertEqual(aligned.dailyExcessReturns.count, expectedDailyExcess.count)
        for (actual, expected) in zip(aligned.dailyExcessReturns.map(\.value), expectedDailyExcess) {
            XCTAssertEqual(actual, expected, accuracy: 0.0000001)
        }
        let incomplete = LocalBacktestDistribution.build(report: report(), benchmarkBars: [bar(0, 100), bar(1, 105)])
        XCTAssertTrue(incomplete.dailyExcessReturns.isEmpty)
        XCTAssertNil(incomplete.summary.benchmarkReturn)
        XCTAssertNil(incomplete.summary.excessReturn)
        XCTAssertTrue(incomplete.summary.unavailableReasons["benchmark"]!.contains("every strategy date"))
    }

    func testFilledExecutionRecordsProvideGrossTradeActivityButNotTurnoverOrPAndL() {
        let order = AshareExecutionOrder(code: "ZZZ", signalDate: date(1), quantity: 100)
        let event = AshareExecutionEvent(order: order, executionDate: date(2), filledQuantity: 100, roundedPrice: 10, commission: 0, stampDuty: 0, slippage: 0, reason: nil)
        let execution = AshareExecutionBacktestReport(events: [event], validCount: 1, skippedCount: 0, finalCash: 0, holdings: ["ZZZ": 100], warnings: [])
        let dataset = LocalBacktestDistribution.build(report: report(), execution: execution)
        XCTAssertNil(dataset.summary.turnover)
        XCTAssertEqual(dataset.summary.grossTradedNotional, 1000)
        XCTAssertEqual(dataset.summary.symbolTradeActivity, [LocalBacktestSymbolTradeActivity(symbol: "ZZZ", tradedNotional: 1000, filledQuantity: 100, fillCount: 1)])
        XCTAssertNil(dataset.summary.symbolContributions)
        XCTAssertNil(dataset.summary.holdingDurationSessions)
        XCTAssertTrue(dataset.summary.unavailableReasons["turnover"]!.contains("portfolio NAV"))
        XCTAssertTrue(dataset.summary.unavailableReasons["holdingDuration"]!.contains("paired open/close"))
        XCTAssertTrue(dataset.summary.unavailableReasons["symbolContributions"]!.contains("realized P&L"))
    }

    func testExecutionReportWithNoFillsIsKnownZeroActivityButUnknownRatios() {
        let execution = AshareExecutionBacktestReport(events: [], validCount: 0, skippedCount: 0,
            finalCash: 0, holdings: [:], warnings: [])
        let dataset = LocalBacktestDistribution.build(report: report(), execution: execution)
        XCTAssertEqual(dataset.summary.grossTradedNotional, 0)
        XCTAssertEqual(dataset.summary.symbolTradeActivity, [])
        XCTAssertNil(dataset.summary.turnover)
        XCTAssertNil(dataset.summary.holdingDurationSessions)
    }
}

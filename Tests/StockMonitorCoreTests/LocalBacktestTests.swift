import XCTest
@testable import StockMonitorCore

final class LocalBacktestTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2024, month: 1, day: day))!
    }

    private func bar(_ code: String, _ day: Int, _ close: Double, amount: Double? = 100,
                     turnover: Double? = nil) -> DailyBar {
        DailyBar(code: code, name: code, tradeDate: date(day), open: close, high: close,
                 low: close, close: close, volume: 1, amount: amount, turnoverRate: turnover, sourceID: "fixture",
                 fetchedAt: date(day), priceAdjustment: "none")
    }

    func testFactorDoesNotLookAheadOnSignalDate() {
        let old = bar("A", 1, 100)
        let changed = bar("A", 2, 200)
        XCTAssertNil(FactorSubset.value(for: .momentum5, observations: [
            FactorObservation(close: old.close), FactorObservation(close: changed.close)
        ]))
    }

    func testSpearmanDirectionAndAverageRankTies() {
        let ranks = LocalBacktest.ranks([10, 10, 20, 30])
        XCTAssertEqual(ranks, [1.5, 1.5, 3, 4])
        let bars = (0..<4).flatMap { offset in
            [bar("A", offset + 1, 100 + Double(offset)), bar("B", offset + 1, 100),
             bar("C", offset + 1, 100 + Double(offset) * 2)]
        }
        let report = LocalBacktest.run(bars: bars, factor: .momentum5, sampleSessions: 4)
        XCTAssertTrue(report.icSeries.isEmpty) // factor warm-up is honored, not fabricated
        XCTAssertEqual(LocalBacktest.run(bars: bars, factor: .peTTM).strataCount, 0)
    }

    func testICAndICIRAndEquityArithmetic() {
        var bars: [DailyBar] = []
        for day in 1...8 {
            bars += [bar("A", day, 100 + Double(day)), bar("B", day, 100), bar("C", day, 100 - Double(day))]
        }
        let report = LocalBacktest.run(bars: bars, factor: .momentum5, sampleSessions: 3)
        XCTAssertFalse(report.icSeries.isEmpty)
        XCTAssertNotNil(report.meanIC)
        XCTAssertNil(report.icir) // constant IC has zero sample deviation
        XCTAssertEqual(LocalBacktest.informationCoefficientRatio([0.5, 0.3])!, 2.82842712474619, accuracy: 1e-10)
        XCTAssertEqual(report.strataCount, 2)
        XCTAssertEqual(report.strata[0].equityCurve.first, 1)
        XCTAssertEqual(report.strata[0].cumulativeReturn!, report.strata[0].equityCurve.last! - 1, accuracy: 1e-12)
        XCTAssertTrue(report.warnings.contains { $0.contains("unadjusted") })
    }

    func testTurnover20IsCalculatedFromDailyKLineField() {
        var bars: [DailyBar] = []
        for day in 1...23 {
            bars += [bar("A", day, 100 + Double(day), turnover: 1 + Double(day) / 100),
                     bar("B", day, 100, turnover: 2),
                     bar("C", day, 100 - Double(day), turnover: 3 - Double(day) / 100)]
        }
        let report = LocalBacktest.run(bars: bars, factor: .turnover20, sampleSessions: 2)
        XCTAssertEqual(report.strataCount, 2)
        XCTAssertEqual(report.icSeries.count, 2)
    }

    func testMissingForwardBarIsSkippedAndSingleStockHasNoIC() {
        var bars: [DailyBar] = []
        for day in 1...20 {
            bars += [bar("A", day, 100, amount: Double(day)),
                     bar("B", day, 100, amount: Double(day + 1)),
                     bar("C", day, 100, amount: Double(day + 2))]
        }
        bars += [bar("A", 21, 110), bar("B", 21, 105)] // C suspended on next session
        let report = LocalBacktest.run(bars: bars, factor: .amount20, sampleSessions: 1)
        XCTAssertTrue(report.warnings.contains { $0.contains("Missing next-session") })
        let oneBars = (1...22).map { bar("A", $0, 100 + Double($0)) }
        let one = LocalBacktest.run(bars: oneBars, factor: .amount20, sampleSessions: 2)
        XCTAssertNil(one.meanIC)
        XCTAssertTrue(one.strata.isEmpty)
    }
}

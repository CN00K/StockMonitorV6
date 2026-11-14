import XCTest
@testable import StockMonitorCore

final class IndicatorsTests: XCTestCase {
    private let calendar = Calendar(identifier: .gregorian)

    private func date(_ day: Int) -> Date { calendar.date(from: DateComponents(year: 2024, month: 1, day: day))! }
    private func bars(_ closes: [Double], highs: [Double]? = nil, lows: [Double]? = nil, volumes: [Int64]? = nil) -> [DailyBar] {
        closes.enumerated().map { i, close in
            let high = highs?[i] ?? close, low = lows?[i] ?? close
            return DailyBar(code: "T", name: "test", tradeDate: date(i + 1), open: close, high: high, low: low,
                            close: close, volume: volumes?[i] ?? 1, fetchedAt: date(i + 1))
        }
    }

    func testBollingerUsesPopulationDeviationAndWarmup() {
        let values = StockIndicators.bollinger(bars([1, 2, 3, 4]), period: 3, multiplier: 2)
        XCTAssertNil(values[0]); XCTAssertNil(values[1])
        XCTAssertEqual(values[2]!.middle, 2, accuracy: 1e-12)
        XCTAssertEqual(values[2]!.upper, 2 + 2 * sqrt(2.0 / 3.0), accuracy: 1e-12)
        XCTAssertEqual(values[2]!.lower, 2 - 2 * sqrt(2.0 / 3.0), accuracy: 1e-12)
    }

    func testEMASeededMACDAndSignalAlignment() {
        let values = macd(bars([1, 2, 3, 4, 5]), fastPeriod: 2, slowPeriod: 3, signalPeriod: 2)
        XCTAssertNil(values[0]); XCTAssertNil(values[1])
        XCTAssertEqual(values[2]!.macd, 0.5, accuracy: 1e-12) // fast SMA 1.5 -> 2.5, slow SMA 2
        XCTAssertNil(values[2]!.signal)
        XCTAssertEqual(values[3]!.macd, 0.5, accuracy: 1e-12)
        XCTAssertEqual(values[3]!.signal!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(values[3]!.histogram!, 0, accuracy: 1e-12)
    }

    func testKDJFlatWindowUsesRSV50AndSmoothing() {
        let values = kdj(bars([10, 10]), period: 2)
        XCTAssertNil(values[0])
        XCTAssertEqual(values[1]!.k, 50, accuracy: 1e-12)
        XCTAssertEqual(values[1]!.d, 50, accuracy: 1e-12)
        XCTAssertEqual(values[1]!.j, 50, accuracy: 1e-12)
    }

    func testATRUsesWilderSeedAndRecurrence() {
        let values = atr(bars([10, 12, 11], highs: [11, 13, 13], lows: [9, 10, 10]), period: 2)
        XCTAssertNil(values[0])
        XCTAssertEqual(values[1]!, 2.5, accuracy: 1e-12) // TRs 2, 3
        XCTAssertEqual(values[2]!, 2.75, accuracy: 1e-12) // (2.5 + 3) / 2
    }

    func testOBVBIASRollingAndStreaks() {
        let fixture = bars([10, 12, 12, 9], volumes: [5, 7, 3, 2])
        XCTAssertEqual(obv(fixture).compactMap { $0 }, [0, 7, 7, 5])
        let biasValues = bias(fixture, period: 2)
        XCTAssertNil(biasValues[0]); XCTAssertEqual(biasValues[1]!, 100.0 * 1 / 11, accuracy: 1e-12)
        let highLow = rollingHighLow(fixture, period: 2)
        XCTAssertNil(highLow[0]); XCTAssertEqual(highLow[1]!.high, 12); XCTAssertEqual(highLow[3]!.low, 9)
        let streaks = consecutiveUpDown(fixture)
        XCTAssertEqual(streaks[0]!.up, 0); XCTAssertEqual(streaks[1]!.up, 1)
        XCTAssertEqual(streaks[2]!.up, 0); XCTAssertEqual(streaks[2]!.down, 0)
        XCTAssertEqual(streaks[3]!.down, 1)
    }

    func testInvalidDatesAndNonFiniteOHLCReturnAlignedNils() {
        var duplicate = bars([1, 2]); duplicate[1] = DailyBar(code: "T", name: "test", tradeDate: date(1), open: 2, high: 2, low: 2, close: 2, volume: 1)
        XCTAssertEqual(StockIndicators.bollinger(duplicate, period: 1).count, 2)
        XCTAssertTrue(StockIndicators.bollinger(duplicate, period: 1).allSatisfy { $0 == nil })
        let invalid = bars([1, .nan, 3])
        XCTAssertTrue(StockIndicators.obv(invalid).allSatisfy { $0 == nil })
        XCTAssertTrue(StockIndicators.atr(invalid, period: 2).allSatisfy { $0 == nil })
    }

    func testInvalidPeriodsPreserveAlignmentAndEmptyInputIsEmpty() {
        let fixture = bars([1, 2, 3])
        XCTAssertEqual(kdj(fixture, period: 0).count, 3)
        XCTAssertTrue(kdj(fixture, period: 0).allSatisfy { $0 == nil })
        XCTAssertTrue(macd(fixture, fastPeriod: 3, slowPeriod: 2).allSatisfy { $0 == nil })
        XCTAssertTrue(rollingHighLow([], period: 2).isEmpty)
    }
}

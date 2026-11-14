import Foundation
import XCTest
@testable import StockMonitorCore

final class MinuteIndicatorsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func bar(_ offset: Int, day: Int = 0, close: Double, volume: Int64 = 100,
                     code: String = "600000") -> MinuteBar {
        let timestamp = base.addingTimeInterval(Double(day * 86_400 + offset * 60))
        return MinuteBar(code: code, name: "测试股", timestamp: timestamp,
            open: close, close: close, high: close, low: close, volume: volume,
            amount: nil, previousClose: nil, sourceID: "fixture", fetchedAt: timestamp)
    }

    private func daily(_ bars: [MinuteBar]) -> [DailyBar] {
        bars.map { DailyBar(code: $0.code, name: $0.name, tradeDate: $0.timestamp,
            open: $0.open, high: $0.high, low: $0.low, close: $0.close,
            volume: $0.volume, sourceID: $0.sourceID, fetchedAt: $0.fetchedAt) }
    }

    func testMinuteOverloadsStayAlignedWithDailyIndicatorInputs() {
        let closes: [Double] = [10, 11, 9, 12, 10, 13, 11, 14, 10, 12]
        let bars = closes.enumerated().map { bar($0.offset, close: $0.element) }
        XCTAssertEqual(StockIndicators.macd(bars, fastPeriod: 2, slowPeriod: 3, signalPeriod: 2).count, bars.count)
        XCTAssertEqual(StockIndicators.kdj(bars, period: 3).count, bars.count)
        XCTAssertEqual(StockIndicators.bollinger(bars, period: 3).count, bars.count)
        XCTAssertEqual(StockIndicators.atr(bars, period: 3).count, bars.count)
        XCTAssertEqual(StockIndicators.obv(bars).count, bars.count)
        XCTAssertEqual(StockIndicators.bias(bars, period: 3).count, bars.count)
        XCTAssertEqual(StockIndicators.rollingHighLow(bars, period: 3).count, bars.count)
        XCTAssertEqual(StockIndicators.consecutiveUpDown(bars).count, bars.count)
        XCTAssertEqual(StockIndicators.rsi(bars, period: 3).count, bars.count)
        XCTAssertEqual(StockIndicators.rsi(daily(bars), period: 3).count, bars.count)
        XCTAssertTrue(StockIndicators.rsi(bars, period: 3).contains { $0 != nil })
    }

    func testMinuteVWAPBandUsesBarVolumeAndResetsForNewShanghaiTradingDate() {
        let bars = [bar(0, close: 10), bar(1, close: 12), bar(2, day: 1, close: 20)]
        let values = StockIndicators.vwapBands(bars)
        XCTAssertEqual(values.count, bars.count)
        XCTAssertEqual(values[0]!.vwap, 10, accuracy: 1e-12)
        XCTAssertEqual(values[0]!.standardDeviation, 0, accuracy: 1e-12)
        XCTAssertEqual(values[1]!.vwap, 11, accuracy: 1e-12)
        XCTAssertEqual(values[1]!.standardDeviation, 1, accuracy: 1e-12)
        XCTAssertEqual(values[1]!.upper, 12, accuracy: 1e-12)
        XCTAssertEqual(values[1]!.lower, 10, accuracy: 1e-12)
        XCTAssertEqual(values[2]!.vwap, 20, accuracy: 1e-12)
        XCTAssertEqual(values[2]!.cumulativeVolume, 100, accuracy: 1e-12)
    }

    func testMinuteVWAPLeavesZeroVolumeUnknownAndRejectsMixedOrUnorderedSeries() {
        let noVolume = [bar(0, close: 10, volume: 0), bar(1, close: 12, volume: 0)]
        XCTAssertTrue(StockIndicators.vwapBands(noVolume).allSatisfy { $0 == nil })

        let mixedCodes = [bar(0, close: 10), bar(1, close: 11, code: "000001")]
        XCTAssertTrue(StockIndicators.bollinger(mixedCodes, period: 1).allSatisfy { $0 == nil })
        XCTAssertTrue(StockIndicators.vwapBands(mixedCodes).allSatisfy { $0 == nil })

        let first = bar(0, close: 10)
        let second = bar(1, close: 11)
        let unordered = [second, first]
        XCTAssertTrue(StockIndicators.rsi(unordered, period: 1).allSatisfy { $0 == nil })
        XCTAssertTrue(StockIndicators.vwapBands(unordered).allSatisfy { $0 == nil })
    }

    func testRSIUsesArithmeticAverageAndKeepsZeroLossUnknown() {
        let mixed = [bar(0, close: 10), bar(1, close: 9), bar(2, close: 11)]
        XCTAssertEqual(StockIndicators.rsi(mixed, period: 2)[2]!, 100.0 * 2.0 / 3.0, accuracy: 1e-12)
        let onlyGains = [bar(0, close: 10), bar(1, close: 11), bar(2, close: 12)]
        XCTAssertNil(StockIndicators.rsi(onlyGains, period: 2)[2])
    }
}

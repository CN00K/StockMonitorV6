import XCTest
@testable import StockMonitorCore

final class AshareExecutionBacktestTests: XCTestCase {
    private let day0 = Date(timeIntervalSince1970: 1_700_000_000)
    private func bar(_ code: String, _ day: Int, _ open: Double, adjustment: String = "none") -> DailyBar {
        DailyBar(code: code, name: code, tradeDate: day0.addingTimeInterval(Double(day) * 86_400),
                 open: open, high: open, low: open, close: open, volume: 10_000,
                 sourceID: "test", priceAdjustment: adjustment)
    }
    private func config(_ side: AshareExecutionSide = .buy, cash: Double = 10_000) -> AshareExecutionConfig {
        AshareExecutionConfig(commissionRate: 0.001, minimumCommission: 5,
                              stampDutyRate: 0.001, slippageRate: 0,
                              tickSize: 0.01, lotSize: 100, side: side, initialCash: cash)
    }

    func testUsesNextSessionAndRoundsToLots() {
        let order = AshareExecutionOrder(code: "600000", signalDate: day0, quantity: 155)
        let report = AshareExecutionBacktest.run(bars: [bar("600000", 1, 10)], orders: [order], config: config())
        XCTAssertEqual(report.validCount, 1)
        XCTAssertEqual(report.events[0].executionDate, day0.addingTimeInterval(86_400))
        XCTAssertEqual(report.events[0].filledQuantity, 100)
    }

    func testCostsAndDeterministicTickRounding() {
        let order = AshareExecutionOrder(code: "600000", signalDate: day0, quantity: 100)
        let c = AshareExecutionConfig(commissionRate: 0.001, minimumCommission: 5,
                                      stampDutyRate: 0.001, slippageRate: 0.01,
                                      tickSize: 0.05, lotSize: 100, side: .buy, initialCash: 2_000)
        let report = AshareExecutionBacktest.run(bars: [bar("600000", 1, 10.01)], orders: [order], config: c)
        let event = try! XCTUnwrap(report.events.first)
        XCTAssertEqual(try! XCTUnwrap(event.roundedPrice), 10.10, accuracy: 0.000_001)
        XCTAssertEqual(event.commission, 5, accuracy: 0.000_001)
        XCTAssertEqual(event.stampDuty, 0, accuracy: 0.000_001)
        XCTAssertEqual(report.finalCash, 985, accuracy: 0.000_001)
    }

    func testExplicitLimitTouchRejectsConservatively() {
        let order = AshareExecutionOrder(code: "600000", signalDate: day0, quantity: 100)
        let limit = AsharePriceLimit(code: "600000", tradeDate: day0.addingTimeInterval(86_400), lower: 9, upper: 10)
        let report = AshareExecutionBacktest.run(bars: [bar("600000", 1, 10)], orders: [order], priceLimits: [limit], config: config())
        XCTAssertEqual(report.validCount, 0)
        XCTAssertEqual(report.events.first?.reason, .priceLimitTouch)
    }

    func testMissingNextBarIsSkippedWithoutForwardFill() {
        let order = AshareExecutionOrder(code: "600000", signalDate: day0, quantity: 100)
        let report = AshareExecutionBacktest.run(bars: [bar("600000", 0, 10)], orders: [order], config: config())
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.events.first?.reason, .missingNextSessionBar)
    }

    func testSellOrderWithoutExplicitT1InventoryIsRejected() {
        let buyDate = day0.addingTimeInterval(86_400)
        let sellOrder = AshareExecutionOrder(code: "600000", signalDate: buyDate, quantity: 100)
        let report = AshareExecutionBacktest.run(bars: [bar("600000", 1, 10), bar("600000", 2, 11)], orders: [sellOrder], config: config(.sell))
        XCTAssertEqual(report.events.first?.reason, .insufficientT1Inventory)
    }

    func testInvalidConfigRejectsAllOrders() {
        let invalid = AshareExecutionConfig(commissionRate: -1, minimumCommission: 0,
                                            stampDutyRate: 0, slippageRate: 0,
                                            tickSize: 0, lotSize: 0, side: .buy)
        let order = AshareExecutionOrder(code: "600000", signalDate: day0, quantity: 100)
        let report = AshareExecutionBacktest.run(bars: [bar("600000", 1, 10)], orders: [order], config: invalid)
        XCTAssertEqual(report.validCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.events.first?.reason, .invalidConfig)
    }
}

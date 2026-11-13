import XCTest
@testable import StockMonitorCore

final class StockMonitorCoreTests: XCTestCase {
    func testSimHashIsStableAcrossWhitespaceAndCase() {
        let first = SimHash.fingerprint("Market  Alert  AAPL")
        let second = SimHash.fingerprint("market alert aapl")
        XCTAssertEqual(first, second)
        XCTAssertTrue(SimHash.isDuplicate(first, second))
    }

    func testPollIntervalAdaptsToWatchCountAndPower() {
        XCTAssertEqual(MarketClock.suggestedInterval(watchCount: 10, lowPowerMode: false, thermalIsElevated: false), 3)
        XCTAssertEqual(MarketClock.suggestedInterval(watchCount: 25, lowPowerMode: false, thermalIsElevated: false), 5)
        XCTAssertEqual(MarketClock.suggestedInterval(watchCount: 90, lowPowerMode: false, thermalIsElevated: false), 10)
        XCTAssertEqual(MarketClock.suggestedInterval(watchCount: 200, lowPowerMode: false, thermalIsElevated: false), 20)
        XCTAssertEqual(MarketClock.suggestedInterval(watchCount: 5, lowPowerMode: true, thermalIsElevated: false), 20)
        XCTAssertEqual(MarketClock.suggestedInterval(watchCount: 5, lowPowerMode: false, thermalIsElevated: true), 15)
    }

    func testTradingSessionUsesChinaTimeAndWeekdays() throws {
        let formatter = ISO8601DateFormatter()
        let inSession = try XCTUnwrap(formatter.date(from: "2026-11-16T10:00:00+08:00"))
        let afterClose = try XCTUnwrap(formatter.date(from: "2026-11-16T15:01:00+08:00"))
        let weekend = try XCTUnwrap(formatter.date(from: "2026-11-15T10:00:00+08:00"))
        XCTAssertTrue(MarketClock.isTradingSession(inSession))
        XCTAssertFalse(MarketClock.isTradingSession(afterClose))
        XCTAssertFalse(MarketClock.isTradingSession(weekend))
        let unsupportedWeekday = try XCTUnwrap(formatter.date(from: "2027-01-04T10:00:00+08:00"))
        XCTAssertEqual(MarketClock.tradingDayStatus(inSession), .open)
        XCTAssertEqual(MarketClock.tradingDayStatus(weekend), .closed(reason: "周末"))
        XCTAssertEqual(MarketClock.tradingDayStatus(unsupportedWeekday), .unknown)
        XCTAssertFalse(MarketClock.isTradingSession(unsupportedWeekday))
        let exchangeHoliday = try XCTUnwrap(formatter.date(from: "2026-10-01T10:00:00+08:00"))
        XCTAssertEqual(MarketClock.tradingDayStatus(exchangeHoliday), .closed(reason: "国庆节"))
        XCTAssertFalse(MarketClock.isTradingSession(exchangeHoliday))
        XCTAssertEqual(MarketClock.verifiedCalendarYears, [2022, 2023, 2024, 2025, 2026])
        for (day, reason) in [
            ("2022-10-03", "国庆节"), ("2023-06-22", "端午节"),
            ("2024-02-09", "春节"), ("2025-10-08", "国庆节、中秋节")
        ] {
            let holiday = try XCTUnwrap(formatter.date(from: "\(day)T10:00:00+08:00"))
            XCTAssertEqual(MarketClock.tradingDayStatus(holiday), .closed(reason: reason))
            XCTAssertFalse(MarketClock.isTradingSession(holiday))
        }
    }

    func testRuleRequiresSustainedTicksAndHonorsCooldown() {
        let rule = WatchRule(id: "move-up", code: "600000", title: "涨幅提醒", detail: "涨幅超过 5%",
                             condition: .changePercentAtLeast(5), sustainedTicks: 2, cooldown: 60)
        var engine = RuleEngine(rules: [rule])
        let quote = Quote(code: "600000", name: "浦发银行", timestamp: Date(timeIntervalSince1970: 1_000),
                          price: 106, previousClose: 100, open: 100, high: 106, low: 99, volume: 10)
        let snapshot = MarketSnapshot(quotes: [quote])
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(engine.evaluate(current: snapshot, now: t0).isEmpty)
        XCTAssertEqual(engine.evaluate(current: snapshot, now: t0.addingTimeInterval(3)).count, 1)
        XCTAssertTrue(engine.evaluate(current: snapshot, now: t0.addingTimeInterval(10)).isEmpty)
        XCTAssertEqual(engine.evaluate(current: snapshot, now: t0.addingTimeInterval(70)).count, 1)
    }

    func testSQLiteRestoresWatchlistSignalsAndLatestTimestamp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = directory.appendingPathComponent("Monitor.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: database)
        try await store.open()
        try await store.setWatchCodes(["600000", "000001"])
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let quote = Quote(code: "600000", name: "浦发银行", timestamp: timestamp,
                          price: 10.2, previousClose: 10, open: 10, high: 10.3, low: 9.9,
                          volume: 1_000, amount: 10_200)
        try await store.insertQuotes([quote])
        let signal = AlertSignal(code: "600000", ruleID: "test", level: .warning,
                                 title: "测试信号", detail: "round trip", createdAt: timestamp)
        try await store.appendSignals([signal])
        let restored = try await store.restoreState()
        XCTAssertEqual(restored.watchCodes, ["000001", "600000"])
        XCTAssertEqual(restored.unreadSignals, [signal])
        XCTAssertEqual(restored.lastQuoteTime, timestamp)
        try await store.checkpoint()
    }
}

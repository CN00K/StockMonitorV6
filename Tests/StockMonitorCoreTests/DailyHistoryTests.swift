import XCTest
@testable import StockMonitorCore

final class DailyHistoryTests: XCTestCase {
    func testParsesDailyKLineFieldsAndMarksUnadjustedSource() throws {
        let fetched = Date(timeIntervalSince1970: 1_800_000_000)
        let bars = EastmoneyDailyHistorySource.parseKLineRows(
            ["2026-11-13,10.00,10.20,10.30,9.90,1000,100000,4.0,0.2,2.0,0.5"],
            code: "600000", name: "浦发银行", fetchedAt: fetched)
        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].open, 10)
        XCTAssertEqual(bars[0].close, 10.2)
        XCTAssertEqual(bars[0].high, 10.3)
        XCTAssertEqual(bars[0].low, 9.9)
        XCTAssertEqual(bars[0].volume, 1000)
        XCTAssertEqual(bars[0].amount, 100000)
        XCTAssertEqual(bars[0].turnoverRate, 0.5)
        XCTAssertEqual(bars[0].sourceID, "eastmoney-kline-daily")
        XCTAssertEqual(bars[0].priceAdjustment, "none")
        XCTAssertEqual(bars[0].fetchedAt, fetched)
    }

    func testRejectsMalformedAndNonFiniteDailyRows() {
        let bars = EastmoneyDailyHistorySource.parseKLineRows([
            "2026-11-13,10,10,11,9,100",
            "2026-11-14,nan,10,11,9,100,1000,0,0,0,0",
            "2026-11-15,10,10,9,11,100,1000,0,0,0,0"
        ], code: "600000", name: "fixture")
        XCTAssertTrue(bars.isEmpty)
    }

    func testDailyBarsPersistAndQueryOnlyRequestedCodeAndRange() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("daily.sqlite"), appGroupIdentifier: nil)
        try await store.open()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let date = try XCTUnwrap(formatter.date(from: "2026-11-13"))
        let bar = DailyBar(code: "600000", name: "fixture", tradeDate: date,
            open: 10, high: 11, low: 9, close: 10.5, volume: 100, amount: 1_000,
            turnoverRate: 0.5, sourceID: "fixture", fetchedAt: date, priceAdjustment: "none")
        try await store.upsertDailyBars([bar])
        let fetched = try await store.fetchDailyBars(codes: ["600000"], from: date.addingTimeInterval(-1), to: date.addingTimeInterval(1))
        XCTAssertEqual(fetched, [bar])
        let otherCode = try await store.fetchDailyBars(codes: ["000001"], from: date.addingTimeInterval(-1), to: date.addingTimeInterval(1))
        XCTAssertTrue(otherCode.isEmpty)
        let outsideRange = try await store.fetchDailyBars(codes: ["600000"], from: date.addingTimeInterval(1), to: date.addingTimeInterval(10))
        XCTAssertTrue(outsideRange.isEmpty)
    }
}

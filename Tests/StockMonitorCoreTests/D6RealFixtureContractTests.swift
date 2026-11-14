import Foundation
import XCTest
@testable import StockMonitorCore

final class D6RealFixtureContractTests: XCTestCase {
    private var fixtureDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Fixtures", isDirectory: true)
    }

    private let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecordedFixtureSidecarsMatchRawSizeAndSuccessStatus() throws {
        let names = [
            "d6-eastmoney-trends2.raw",
            "d6-eastmoney-daily-kline.raw",
            "d6-cninfo-stock-map.raw",
            "d6-thepaper-news.raw",
            "d6-gov-policy.raw",
            "d6-eastmoney-lhb.raw"
        ]
        for name in names {
            let data = try Data(contentsOf: fixtureDirectory.appendingPathComponent(name))
            let metadataData = try Data(contentsOf: fixtureDirectory.appendingPathComponent(name + ".json"))
            let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
            XCTAssertEqual(metadata["http_status"] as? Int, 200, name)
            XCTAssertEqual(metadata["byte_count"] as? Int, data.count, name)
            XCTAssertTrue((metadata["source_url"] as? String)?.hasPrefix("https://") == true, name)
            XCTAssertNotNil(metadata["retrieval_timestamp"] as? String, name)
        }
    }

    func testRecordedTrends2FixtureUsesObservedMinuteColumns() throws {
        let root = try jsonObject("d6-eastmoney-trends2.raw")
        let payload = try XCTUnwrap(root["data"] as? [String: Any])
        let rows = try XCTUnwrap(payload["trends"] as? [String])
        XCTAssertEqual(rows.count, 1_205)
        let bars = EastmoneyMinuteHistorySource.parseTrendRows(rows, code: "600000", name: "浦发银行", fetchedAt: fetchedAt)
        XCTAssertEqual(bars.count, rows.count)
        XCTAssertEqual(bars.first?.code, "600000")
        XCTAssertEqual(bars.first?.sourceID, "eastmoney-trends2")
        XCTAssertEqual(bars.first?.close, 9.94)
        XCTAssertEqual(bars.first?.volume, 8_302)
        XCTAssertEqual(bars.first?.amount, 8_252_188)
        XCTAssertEqual(bars.last?.close, 10.40)
        XCTAssertEqual(bars.last?.volume, 9_769)
    }

    func testRecordedDailyKlineFixtureUsesObservedFieldsAndDateRange() throws {
        let root = try jsonObject("d6-eastmoney-daily-kline.raw")
        let payload = try XCTUnwrap(root["data"] as? [String: Any])
        let rows = try XCTUnwrap(payload["klines"] as? [String])
        XCTAssertEqual(rows.count, 10)
        let bars = EastmoneyDailyHistorySource.parseKLineRows(rows, code: "600000", name: "浦发银行", fetchedAt: fetchedAt)
        XCTAssertEqual(bars.count, 10)
        XCTAssertEqual(chinaDateString(bars.first!.tradeDate), "2026-11-02")
        XCTAssertEqual(chinaDateString(bars.last!.tradeDate), "2026-11-13")
        XCTAssertEqual(bars.first?.close, 10.06)
        XCTAssertEqual(bars.first?.volume, 1_164_223)
        XCTAssertEqual(bars.first?.turnoverRate, 0.35)
        XCTAssertEqual(bars.last?.close, 10.40)
        XCTAssertEqual(bars.last?.priceAdjustment, "none")
    }

    func testRecordedCNINFOStockMapFixtureUsesStockListEnvelope() throws {
        let map = try CNInfoAnnouncementSource.parseStockMap(fixtureData("d6-cninfo-stock-map.raw"))
        XCTAssertGreaterThan(map.count, 1_000)
        XCTAssertEqual(map["000001"], "gssz0000001")
        XCTAssertNil(map["600000"], "The current adapter deliberately returns only verified SZSE prefixes")
    }

    func testRecordedThePaperFixtureParsesHotNewsRows() throws {
        let root = try jsonObject("d6-thepaper-news.raw")
        XCTAssertEqual(root["resultCode"] as? Int, 1)
        let data = try XCTUnwrap(root["data"] as? [String: Any])
        let rows = try XCTUnwrap(data["hotNews"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 20)
        let events = rows.compactMap { ThePaperNewsSource.parseRow($0, fetchedAt: fetchedAt) }
        XCTAssertGreaterThan(events.count, 0)
        XCTAssertTrue(events.allSatisfy { $0.sourceID == "thepaper" })
        XCTAssertNotNil(events.first?.sourceItemID)
    }

    func testRecordedGovernmentFixtureParsesActualSearchResultRows() throws {
        let root = try jsonObject("d6-gov-policy.raw")
        XCTAssertEqual(root["code"] as? Int, 200)
        let search = try XCTUnwrap(root["searchVO"] as? [String: Any])
        var rows: [[String: Any]] = []
        if let categories = search["catMap"] as? [String: Any] {
            for key in categories.keys.sorted() {
                if let group = categories[key] as? [String: Any],
                   let list = group["listVO"] as? [[String: Any]] { rows.append(contentsOf: list) }
            }
        }
        if let list = search["listVO"] as? [[String: Any]] { rows.append(contentsOf: list) }
        XCTAssertGreaterThan(rows.count, 0)
        let events = rows.compactMap { GovCNPolicySource.parseRow($0, fetchedAt: fetchedAt) }
        XCTAssertGreaterThan(events.count, 0)
        XCTAssertTrue(events.allSatisfy { $0.sourceID == "gov" && !$0.title.isEmpty })
    }

    func testRecordedDragonTigerFixtureParsesSummaryWithoutInventingPublishTime() throws {
        let root = try jsonObject("d6-eastmoney-lhb.raw")
        let result = try XCTUnwrap(root["result"] as? [String: Any])
        let rows = try XCTUnwrap(result["data"] as? [[String: Any]])
        XCTAssertEqual(rows.count, 1)
        let event = try XCTUnwrap(rows.compactMap { EastmoneyDragonTigerSource.parseSummaryRow($0, fetchedAt: fetchedAt) }.first)
        XCTAssertEqual(event.kind, .dragonTiger)
        XCTAssertEqual(event.sourceID, "eastmoney_lhb")
        XCTAssertEqual(event.stockCodes, ["600000"])
        XCTAssertFalse(event.providerTimestampVerified)
        XCTAssertEqual(event.title, "龙虎榜：浦发银行（600000）上榜")
    }

    private func fixtureData(_ name: String) throws -> Data {
        try Data(contentsOf: fixtureDirectory.appendingPathComponent(name))
    }

    private func jsonObject(_ name: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: fixtureData(name)) as? [String: Any])
    }

    private func chinaDateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

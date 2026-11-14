import Foundation
import XCTest
@testable import StockMonitorCore

final class EventAnalyticsB7Tests: XCTestCase {
    func testObservablePolicyReasonsAreDeterministic() {
        let policy = CollectorEventPolicy()
        let noSector = MarketEvent(sourceID: "feed", title: "孤立消息", priority: 2)
        XCTAssertEqual(policy.rejectionReason(for: noSector), "low_priority_no_sector")
        let individualPolicy = CollectorEventPolicy(lowPriorityNoSectorEnabled: false)
        let individual = MarketEvent(sourceID: "feed", title: "个股消息", priority: 2, impactScope: .stock)
        XCTAssertEqual(individualPolicy.rejectionReason(for: individual), "low_value_individual")
        XCTAssertTrue(policy.keep(MarketEvent(sourceID: "feed", title: "重要", priority: 5)))
    }

    func testKeywordTokenizerAndUnknownBaselineAreDeterministic() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let latest = MarketEvent(sourceID: "x", title: "银行 ABC 银行", publishedAt: now.addingTimeInterval(-60), fetchedAt: now)
        let report = EventKeywordFrequencyReport.compare(events: [latest], now: now, top: 10)
        XCTAssertEqual(report.latestSampleCount, 1)
        XCTAssertEqual(report.baselineSampleCount, 0)
        XCTAssertEqual(report.missingReasons, ["preceding_24h_has_no_events"])
        XCTAssertEqual(report.frequencies.first(where: { $0.token == "银行" })?.latestCount, 2)
        XCTAssertNil(report.frequencies.first(where: { $0.token == "银行" })?.growthPercent)
        XCTAssertEqual(report.frequencies.first(where: { $0.token == "abc" })?.latestCount, 1)
        XCTAssertEqual(EventKeywordTokenizer.tokenize("中国证券市场"), ["中国", "国证", "证券", "券市", "市场"])
    }

    func testKeywordGrowthComparesTwoExplicitTwentyFourHourWindows() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let events = [
            MarketEvent(sourceID: "x", title: "银行", publishedAt: now.addingTimeInterval(-60), fetchedAt: now),
            MarketEvent(sourceID: "x", title: "银行", publishedAt: now.addingTimeInterval(-120), fetchedAt: now),
            MarketEvent(sourceID: "x", title: "银行", publishedAt: now.addingTimeInterval(-25 * 60 * 60), fetchedAt: now)
        ]
        let report = EventKeywordFrequencyReport.compare(events: events, now: now)
        let bank = report.frequencies.first(where: { $0.token == "银行" })
        XCTAssertEqual(report.latestSampleCount, 2)
        XCTAssertEqual(report.baselineSampleCount, 1)
        XCTAssertEqual(bank?.latestCount, 2)
        XCTAssertEqual(bank?.baselineCount, 1)
        XCTAssertEqual(bank?.growthPercent, 100)
    }

    func testSQLitePersistsReasonCountsWithoutEventPayload() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("B7.sqlite"))
        try await store.open()
        let now = Date(timeIntervalSince1970: 2_000_000)
        try await store.recordEventRejections([
            EventRejectionDecision(eventID: "e1", sourceID: "feed", reason: "low_priority_no_sector", decidedAt: now),
            EventRejectionDecision(eventID: "e2", sourceID: "feed", reason: "low_priority_no_sector", decidedAt: now),
            EventRejectionDecision(eventID: "e3", sourceID: "feed", reason: "low_value_individual", decidedAt: now)
        ])
        let counts = try await store.eventRejectionCounts(from: now.addingTimeInterval(-1), to: now.addingTimeInterval(1))
        XCTAssertEqual(counts, ["low_priority_no_sector": 2, "low_value_individual": 1])
        let report = try await store.eventKeywordFrequencyReport(now: now)
        XCTAssertEqual(report.latestSampleCount, 0)
        XCTAssertEqual(report.baselineSampleCount, 0)
        XCTAssertTrue(report.missingReasons.contains("latest_24h_has_no_events"))
    }
}

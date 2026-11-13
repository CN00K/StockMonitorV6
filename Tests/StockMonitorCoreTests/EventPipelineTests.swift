import Foundation
import XCTest
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#else
#error("SQLite3 or the SwiftPM CSQLite system library is required")
#endif
@testable import StockMonitorCore

final class EventPipelineTests: XCTestCase {
    private let fetchedAt = Date(timeIntervalSince1970: 1_794_589_800)

    func testCLSParserUsesBriefWhenTitleIsEmptyAndExcludesAds() throws {
        let fixture: [String: Any] = [
            "id": 2534295, "ctime": 1_794_589_469, "title": "", "brief": "财联社快讯：银行板块出现异动",
            "content": "财联社快讯：银行板块出现异动", "shareurl": "https://api3.cls.cn/share/article/2534295",
            "level": "C", "is_ad": 0, "subjects": [["subject_name": "银行"]],
            "stock_list": [["secu_code": "600000"]]
        ]
        let event = try XCTUnwrap(CLSTelegraphSource.parseRow(fixture, fetchedAt: fetchedAt))
        XCTAssertEqual(event.sourceID, "cls")
        XCTAssertEqual(event.sourceItemID, "2534295")
        XCTAssertEqual(event.title, "财联社快讯：银行板块出现异动")
        XCTAssertEqual(event.sectors, ["银行"])
        XCTAssertEqual(event.stockCodes, ["600000"])
        XCTAssertTrue(event.providerTimestampVerified)
        XCTAssertNil(CLSTelegraphSource.parseRow(["id": 1, "title": "广告", "is_ad": 1], fetchedAt: fetchedAt))
    }

    func testEastmoneyThePaperAndGovernmentFixtures() throws {
        let eastmoney = try XCTUnwrap(EastmoneyNewsSource.parseRow([
            "id": "list-1", "newsid": "20261114001", "title": "上市公司发布公告",
            "digest": "公告摘要", "showtime": "2026-11-14 10:05:00", "url_unique": "https://finance.eastmoney.com/a/20261114001.html"
        ], fetchedAt: fetchedAt))
        XCTAssertEqual(eastmoney.sourceID, "eastmoney_news")
        XCTAssertEqual(eastmoney.sourceItemID, "20261114001")
        XCTAssertNotNil(eastmoney.publishedAt)

        let paper = try XCTUnwrap(ThePaperNewsSource.parseRow([
            "contId": "34468448", "name": "政策要闻标题", "pubTimeLong": 1_794_564_057_572 as Int64,
            "summary": "政策摘要", "link": ""
        ], fetchedAt: fetchedAt))
        XCTAssertEqual(paper.sourceID, "thepaper")
        XCTAssertEqual(paper.sourceItemID, "34468448")
        XCTAssertTrue(paper.providerTimestampVerified)
        XCTAssertNil(paper.url)

        let government = try XCTUnwrap(GovCNPolicySource.parseRow([
            "id": "26926511", "title": "<em>证券</em>行业政策", "summary": "政策摘要",
            "url": "https://www.gov.cn/zhengce/example.htm", "pubtime": "1794589200000",
            "puborg": "国务院"
        ], fetchedAt: fetchedAt))
        XCTAssertEqual(government.title, "证券行业政策")
        XCTAssertEqual(government.sourceID, "gov")
        XCTAssertEqual(government.priority, 5)
        XCTAssertNotNil(government.publishedAt)
    }

    func testCNINFOAndEastmoneyDragonTigerFixtures() throws {
        let stockMap = Data("""
        [{"code":"000001","orgId":"gssz0000001","zwjc":"平安银行"},{"code":"600000","orgId":"gssh0000001"}]
        """.utf8)
        XCTAssertEqual(try CNInfoAnnouncementSource.parseStockMap(stockMap), ["000001": "gssz0000001"])

        let announcement = try XCTUnwrap(CNInfoAnnouncementSource.parseAnnouncement([
            "announcementId": "1225620612", "secCode": "000001", "secName": "平安银行",
            "announcementTitle": "关联交易公告", "announcementTime": 1_792_771_200_000 as Int64,
            "adjunctUrl": "finalpage/2026-10-24/1225620612.PDF", "adjunctType": "PDF",
            "announcementContent": ""
        ], fetchedAt: fetchedAt))
        XCTAssertEqual(announcement.kind, .announcement)
        XCTAssertEqual(announcement.sourceID, "cninfo")
        XCTAssertEqual(announcement.stockCodes, ["000001"])
        XCTAssertEqual(announcement.url, "https://static.cninfo.com.cn/finalpage/2026-10-24/1225620612.PDF")
        XCTAssertNil(announcement.body)

        let billboard = try XCTUnwrap(EastmoneyDragonTigerSource.parseSummaryRow([
            "TRADE_DATE": "2026-11-13", "SECURITY_CODE": "600000", "SECURITY_NAME_ABBR": "浦发银行",
            "EXPLANATION": "日涨幅偏离值达到7%", "CHANGE_RATE": "9.98",
            "BILLBOARD_BUY_AMT": "1000000", "BILLBOARD_SELL_AMT": "200000", "BILLBOARD_NET_AMT": "800000",
            "TRADE_ID": "trade-123"
        ], fetchedAt: fetchedAt))
        XCTAssertEqual(billboard.kind, .dragonTiger)
        XCTAssertEqual(billboard.sourceID, "eastmoney_lhb")
        XCTAssertEqual(billboard.sourceItemID, "trade-123")
        XCTAssertFalse(billboard.providerTimestampVerified)
        XCTAssertTrue(billboard.body?.contains("日涨幅偏离值") == true)
    }

    func testBlockedSourcesAreExplicitlyUnavailableWithoutRequests() async {
        let since = Date(timeIntervalSince1970: 1_700_000_000)
        let xueqiu = await XueqiuUnavailableSource().fetch(since: since, limit: 10)
        let miit = await MIITUnavailableSource().fetch(since: since, limit: 10)
        XCTAssertEqual(xueqiu.status.sourceID, "xueqiu")
        XCTAssertEqual(xueqiu.status.requestCount, 0)
        XCTAssertNotNil(xueqiu.status.error)
        XCTAssertEqual(miit.status.sourceID, "miit")
        XCTAssertEqual(miit.status.requestCount, 0)
        XCTAssertNotNil(miit.status.error)
    }

    func testCollectorYAMLPrioritiesAndLowValueFilter() throws {
        let yaml = """
        title_similarity_threshold: 0.85
        event_filter:
          enabled: true
          rules:
            low_priority_no_sector:
              enabled: true
              max_priority: 2
            low_value_individual:
              enabled: true
              max_priority: 2
              min_news_count: 2
            always_keep:
              min_priority: 3
              or_news_count: 3
        source_priority:
          P1: [gov, cninfo]
          P2: [miit]
          P3: [cls, eastmoney_lhb]
          P4: [eastmoney_news, thepaper]
          P5: [xueqiu]
        """
        let policy = CollectorEventPolicy.parseYAML(yaml)
        XCTAssertEqual(policy.priority(for: "cninfo"), 5)
        XCTAssertEqual(policy.priority(for: "eastmoney_lhb"), 3)
        XCTAssertEqual(policy.priority(for: "eastmoney_news"), 2)
        let lowValue = MarketEvent(sourceID: "eastmoney_news", title: "孤立个股新闻",
            fetchedAt: fetchedAt, priority: 2, impactScope: .stock)
        let official = MarketEvent(sourceID: "gov", title: "官方政策", fetchedAt: fetchedAt, priority: 5)
        XCTAssertFalse(policy.keep(lowValue))
        XCTAssertTrue(policy.keep(official))

        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packaged = try String(contentsOf: projectRoot.appendingPathComponent("Resources/collector.yaml"), encoding: .utf8)
        let packagedPolicy = CollectorEventPolicy.parseYAML(packaged)
        XCTAssertEqual(packagedPolicy.priority(for: "cninfo"), 5)
        XCTAssertEqual(packagedPolicy.priority(for: "eastmoney_news"), 2)
        XCTAssertEqual(packagedPolicy.priority(for: "eastmoney_lhb"), 3)
    }

    func testImportedMITSectorSeedEnrichesEventClusters() throws {
        let projectRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: projectRoot.appendingPathComponent("Resources/sector_map.json"))
        let tagger = try SectorTagger(data: data)
        let event = MarketEvent(sourceID: "cls", title: "电力储能产业链政策动态",
            publishedAt: fetchedAt, fetchedAt: fetchedAt, priority: 3)
        let processed = EventProcessor(sectorTagger: tagger).process([event])
        XCTAssertEqual(processed.count, 1)
        XCTAssertTrue(processed[0].sectors.contains("电力"))
        XCTAssertTrue(processed[0].sectors.contains("储能"))
    }

    func testStockCodeExtractionIncludesBeijingExchangePrefix() {
        let event = MarketEvent(sourceID: "cls", title: "北交所公司 430001 发布业绩公告",
            fetchedAt: fetchedAt, priority: 3)
        let processed = EventProcessor().process([event])
        XCTAssertEqual(processed.first?.stockCodes, ["430001"])
    }

    func testDedupeSummaryAndLocalSQLiteRoundTrip() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = directory.appendingPathComponent("Events.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: database)
        try await store.open()
        let day = ISO8601DateFormatter().date(from: "2026-11-14T10:00:00+08:00")!
        let primary = MarketEvent(sourceID: "cls", sourceItemID: "cls-1", title: "浦发银行发布重要经营公告 600000",
            body: "经营信息", publishedAt: day, fetchedAt: day, providerTimestampVerified: true,
            priority: 3, impactScope: .stock, stockCodes: ["600000"])
        let secondary = MarketEvent(sourceID: "eastmoney_news", sourceItemID: "em-1", title: "浦发银行发布重要经营公告 600000",
            body: "媒体摘要", publishedAt: day.addingTimeInterval(30), fetchedAt: day, providerTimestampVerified: true,
            priority: 2, impactScope: .stock, stockCodes: ["600000"])
        let sourceA = FixedEventSource(identifier: "cls", events: [primary])
        let sourceB = FixedEventSource(identifier: "eastmoney_news", events: [secondary])
        let collector = EventCollector(store: store, sources: [sourceA, sourceB], processor: EventProcessor())
        let report = await collector.refresh(since: day.addingTimeInterval(-60), stockCodes: ["600000"])
        XCTAssertEqual(report.receivedCount, 2)
        XCTAssertEqual(report.storedCount, 2)
        XCTAssertEqual(report.visibleCount, 1)
        let stored = try await store.fetchEvents(from: day.addingTimeInterval(-60), to: day.addingTimeInterval(86_400))
        XCTAssertEqual(stored.count, 2)
        XCTAssertEqual(stored.map(\.sourceID).sorted(), ["cls", "eastmoney_news"])
        let summary = try await collector.dailySummary(on: day)
        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertEqual(summary.clusterCount, 1)
        XCTAssertEqual(summary.clusters.first?.eventCount, 2)
        XCTAssertEqual(summary.clusters.first?.sourceIDs, ["cls", "eastmoney_news"])
    }

    func testCollectorPersistsP1HealthValidityAndRawResponseArchive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("Collector.sqlite"))
        try await store.open()
        let now = Date()
        let event = MarketEvent(sourceID: "gov", title: "官方行业政策公告", publishedAt: now,
            fetchedAt: now, priority: 5, impactScope: .sector, sectors: ["银行"])
        let raw = RawEventResponse(sourceID: "gov",
            url: try XCTUnwrap(URL(string: "https://www.gov.cn/search?q=private-query")),
            fetchedAt: now, contentType: "application/json", data: Data("{\"rows\":[]}".utf8))
        let collector = EventCollector(store: store,
            sources: [ReportingFixedEventSource(event: event, rawResponse: raw)], processor: EventProcessor())
        let report = await collector.refresh(since: now.addingTimeInterval(-60))
        XCTAssertEqual(report.storedCount, 1)
        XCTAssertEqual(report.visibleCount, 1)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let day = calendar.startOfDay(for: now)
        let health = try await store.fetchSourceHealth(from: day, through: now.addingTimeInterval(1))
        XCTAssertEqual(health.p1Successes, 1)
        XCTAssertEqual(health.p1Attempts, 1)
        XCTAssertEqual(health.filterKept, 1)
        XCTAssertEqual(health.filterTotal, 2)
        XCTAssertEqual(health.ruleOrSkippedDecisions, 1)

        let archive = try await store.fetchRawArchive()
        XCTAssertEqual(archive.count, 1)
        let archived = try XCTUnwrap(archive.first)
        XCTAssertNil(URLComponents(string: archived.endpoint)?.query)
        XCTAssertFalse(archived.endpoint.contains("private-query"))
    }

    func testDedupeDoesNotMergeDifferentExplicitStocks() {
        let first = MarketEvent(sourceID: "cls", title: "重大事项提示性公告",
            publishedAt: fetchedAt, fetchedAt: fetchedAt, priority: 3,
            impactScope: .stock, stockCodes: ["600000"])
        let second = MarketEvent(sourceID: "gov", title: "重大事项提示性公告",
            publishedAt: fetchedAt, fetchedAt: fetchedAt, priority: 5,
            impactScope: .stock, stockCodes: ["000001"])
        let clusters = EventProcessor().process([first, second])
        XCTAssertEqual(clusters.count, 2)
        XCTAssertEqual(Set(clusters.compactMap { $0.stockCodes.first }), ["000001", "600000"])
    }

    func testCSVAndJSONExportPreserveQuotesAndMetadata() throws {
        let event = MarketEvent(sourceID: "cls", sourceItemID: "1", title: "标题,含\"引号\"",
            body: "正文", publishedAt: fetchedAt, fetchedAt: fetchedAt, providerTimestampVerified: true,
            priority: 3, impactScope: .sector, sectors: ["银行"], stockCodes: ["600000"])
        let csv = String(decoding: try EventExporter.encode(events: [event], format: .csv), as: UTF8.self)
        XCTAssertTrue(csv.contains("\"标题,含\"\"引号\"\"\""))
        XCTAssertTrue(csv.contains("provider_timestamp_verified"))
        let formula = MarketEvent(sourceID: "cls", title: "=HYPERLINK(\"https://example.invalid\")",
            fetchedAt: fetchedAt)
        let formulaCSV = String(decoding: try EventExporter.encode(events: [formula], format: .csv), as: UTF8.self)
        XCTAssertTrue(formulaCSV.contains("\"'=HYPERLINK"))
        let json = try EventExporter.encode(events: [event], format: .json)
        let decoded = try JSONDecoder.iso8601.decode([MarketEvent].self, from: json)
        XCTAssertEqual(decoded, [event])
    }

    func testSQLiteFTSMigrationIndexesLegacyEventsAndSupportsShortTerms() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = directory.appendingPathComponent("LegacyEvents.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let event = MarketEvent(sourceID: "gov", sourceItemID: "legacy-1", title: "浦发银行投资者交流公告",
            body: "银行板块经营情况", publishedAt: fetchedAt, fetchedAt: fetchedAt,
            priority: 5, impactScope: .stock, sectors: ["银行"], stockCodes: ["600000"])
        try createLegacyEventsDatabase(at: database, containing: event)

        let store = SQLiteMonitorStore(databaseURL: database)
        // The first search exercises ensureOpen()'s lazy schema-migration path.
        let fullText = try await store.searchEvents(matching: "浦发银行")
        XCTAssertEqual(fullText.map(\.id), [event.id])
        let shortTerm = try await store.searchEvents(matching: "银行")
        XCTAssertEqual(shortTerm.map(\.id), [event.id])
        let codeSearch = try await store.searchEvents(matching: "600000")
        XCTAssertEqual(codeSearch.map(\.id), [event.id])

        let replacement = MarketEvent(id: event.id, sourceID: event.sourceID, sourceItemID: event.sourceItemID,
            title: "平安银行投资者交流公告", body: "金融行业动态", publishedAt: event.publishedAt,
            fetchedAt: fetchedAt.addingTimeInterval(1), priority: 5, impactScope: .stock,
            sectors: ["金融"], stockCodes: ["000001"])
        try await store.upsertEvents([replacement])
        let oldTitleResults = try await store.searchEvents(matching: "浦发银行")
        let newTitleResults = try await store.searchEvents(matching: "平安银行")
        XCTAssertTrue(oldTitleResults.isEmpty)
        XCTAssertEqual(newTitleResults.map(\.id), [event.id])
    }

    func testRawResponseArchiveRedactsQueryAndPrunesByAgeAndTotalBytes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("Archive.sqlite"))
        try await store.open()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let url = try XCTUnwrap(URL(string: "https://feed.example.invalid/news?token=do-not-store"))
        let stale = RawEventResponse(sourceID: "gov", url: url,
            fetchedAt: now.addingTimeInterval(-RawResponseArchiveLimits.retention - 1), data: Data("old".utf8))
        let fresh = RawEventResponse(sourceID: "gov", url: url, fetchedAt: now,
            contentType: "application/json", data: Data("{\"ok\":true}".utf8))
        let archivedFreshCount = try await store.archiveRawResponses([stale, fresh], at: now)
        XCTAssertEqual(archivedFreshCount, 1)
        var records = try await store.fetchRawArchive()
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(URLComponents(string: records[0].endpoint)?.query)
        XCTAssertFalse(records[0].endpoint.contains("do-not-store"))
        XCTAssertEqual(records[0].payload, fresh.data)

        let tooLarge = RawEventResponse(sourceID: "gov", url: url, fetchedAt: now,
            data: Data(repeating: 0x41, count: RawResponseArchiveLimits.maximumResponseBytes + 1))
        let archivedOversizeCount = try await store.archiveRawResponses([tooLarge], at: now)
        XCTAssertEqual(archivedOversizeCount, 0)

        let chunk = Data(repeating: 0x42, count: 500_000)
        for batch in 0..<6 {
            let responses = (0..<4).map { index in
                RawEventResponse(sourceID: "gov", url: url,
                    fetchedAt: now.addingTimeInterval(Double(batch * 4 + index + 1)), data: chunk)
            }
            let archivedCount = try await store.archiveRawResponses(responses, at: now.addingTimeInterval(Double(batch + 1)))
            XCTAssertEqual(archivedCount, 4)
        }
        let stats = try await store.rawArchiveStats()
        XCTAssertLessThanOrEqual(stats.byteCount, RawResponseArchiveLimits.maximumStoredBytes)
        XCTAssertLessThanOrEqual(stats.responseCount, RawResponseArchiveLimits.maximumStoredResponses)
        records = try await store.fetchRawArchive(limit: 500)
        XCTAssertEqual(records.reduce(0) { $0 + $1.byteCount }, stats.byteCount)
    }

    func testSourceHealthAccumulatesByChinaDayAndAppliesDocumentedThresholds() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("Health.sqlite"))
        try await store.open()
        let day = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.recordSourceHealth(SourceHealthDelta(day: day, p1Successes: 49, p1Attempts: 50,
            filterKept: 4, filterTotal: 5, llmEnrichedDecisions: 1))
        try await store.recordSourceHealth(SourceHealthDelta(day: day, p1Successes: 50, p1Attempts: 50,
            filterKept: 4, filterTotal: 5, ruleOrSkippedDecisions: 1))
        try await store.recordSourceHealth(SourceHealthDelta(day: day.addingTimeInterval(86_400),
            p1Attempts: 10, filterTotal: 10, ruleOrSkippedDecisions: 10))

        let sameDay = try await store.fetchSourceHealth(from: day, through: day)
        XCTAssertEqual(sameDay.p1Successes, 99)
        XCTAssertEqual(sameDay.p1Attempts, 100)
        XCTAssertEqual(sameDay.filterKept, 8)
        XCTAssertEqual(sameDay.filterTotal, 10)
        XCTAssertEqual(sameDay.llmEnrichedDecisions, 1)
        XCTAssertEqual(sameDay.ruleOrSkippedDecisions, 1)
        XCTAssertEqual(sameDay.p1SuccessRate, 0.99, accuracy: 0.000_001)
        XCTAssertEqual(sameDay.eventValidityRate, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(sameDay.llmCallShare, 0.5, accuracy: 0.000_001)
        XCTAssertTrue(sameDay.p1ThresholdPassed)
        XCTAssertTrue(sameDay.eventValidityThresholdPassed)
        XCTAssertTrue(sameDay.llmCallShareThresholdPassed)
    }

    private func createLegacyEventsDatabase(at url: URL, containing event: MarketEvent) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        let database = try XCTUnwrap(handle)
        defer { sqlite3_close(database) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = String(decoding: try encoder.encode(event), as: UTF8.self)
        func quoted(_ value: String) -> String { "'\(value.replacingOccurrences(of: "'", with: "''"))'" }
        let eventTime = (event.publishedAt ?? event.fetchedAt).timeIntervalSince1970
        let sql = """
        CREATE TABLE events(id TEXT PRIMARY KEY NOT NULL, event_time REAL NOT NULL, fetched_at REAL NOT NULL, source_id TEXT NOT NULL, priority INTEGER NOT NULL, payload TEXT NOT NULL);
        INSERT INTO events(id,event_time,fetched_at,source_id,priority,payload) VALUES(\(quoted(event.id)),\(eventTime),\(event.fetchedAt.timeIntervalSince1970),\(quoted(event.sourceID)),\(event.priority),\(quoted(payload)));
        PRAGMA user_version=0;
        """
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sql.withCString { sqlite3_exec(database, $0, nil, nil, &errorMessage) }
        let message = errorMessage.map { String(cString: $0) } ?? ""
        sqlite3_free(errorMessage)
        XCTAssertEqual(result, SQLITE_OK, message)
    }
}

private struct FixedEventSource: MarketEventSource {
    let identifier: String
    let events: [MarketEvent]

    func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        let filtered = Array(events.filter { ($0.publishedAt ?? .distantPast) >= since }.prefix(limit))
        return EventFetchBatch(events: filtered, status: EventSourceStatus(sourceID: identifier,
            latestPublishedAt: filtered.compactMap(\.publishedAt).max(), requestedCount: limit,
            returnedCount: filtered.count, requestCount: 0, note: "fixture"))
    }
}

private struct ReportingFixedEventSource: MarketEventSource {
    let event: MarketEvent
    let rawResponse: RawEventResponse
    var identifier: String { "gov" }

    func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        EventFetchBatch(events: [event], status: EventSourceStatus(sourceID: identifier,
            fetchedAt: rawResponse.fetchedAt, latestPublishedAt: event.publishedAt,
            requestedCount: limit, returnedCount: 1, requestCount: 1,
            successfulRequestCount: 1, candidateRecordCount: 2, validRecordCount: 1),
            rawResponses: [rawResponse])
    }
}

private extension JSONDecoder {
    static var iso8601: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

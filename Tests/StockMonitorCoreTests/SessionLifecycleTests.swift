import XCTest
@testable import StockMonitorCore

final class SessionLifecycleTests: XCTestCase {
    func testStartRestoresStateReconcilesAndStopCheckpointsWithoutFurtherPolling() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T10:00:00+08:00"))
        let rule = WatchRule(id: "price", code: "600000", title: "价格到达", detail: "到达阈值",
                             condition: .priceAtLeast(10), sustainedTicks: 1, cooldown: 0)
        let holding = Holding(code: "600000", shares: 200, averageCost: 9.8, updatedAt: now)
        let restored = RestoredState(watchCodes: ["600000"], watchRules: [rule], holdings: [holding],
            unreadSignals: [], latestQuotes: [], latestIndexQuotes: [], lastQuoteTime: nil,
            lastQuoteTimeByCode: [:], lastMinuteTimestampByCode: [:])
        let store = MemoryMonitorStore(restored: restored)
        let provider = CountingMarketProvider(timestamp: now)
        let historyBar = MinuteBar(code: "600000", name: "浦发银行", timestamp: now.addingTimeInterval(-60),
            open: 10, close: 10, high: 10.1, low: 9.9, volume: 100, amount: 1_000,
            previousClose: 9.8, sourceID: "fixture-history", fetchedAt: now)
        let history = FixtureHistorySource(bar: historyBar)
        let engine = LiveEngine(store: store, source: provider, historicalSource: history)

        await engine.start(now: now)
        var live = await engine.state(now: now)
        for _ in 0..<100 {
            if live.latestSnapshot?.quotes.first?.sourceID == "fixture",
               live.reconcileReport?.barCount == 1, !live.unreadSignals.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
            live = await engine.state(now: now)
        }
        XCTAssertEqual(live.phase, .live)
        XCTAssertEqual(live.watchCodes, ["600000"])
        XCTAssertEqual(live.watchRules, [rule])
        XCTAssertEqual(live.holdings, [holding])
        XCTAssertEqual(live.latestSnapshot?.quotes.first?.sourceID, "fixture")
        XCTAssertEqual(live.latestSnapshot?.limits["600000"], LimitPair(up: 10.78, down: 8.82))
        XCTAssertTrue(live.limitPriceStatus.contains("本地估算"))
        XCTAssertTrue(live.limitPriceStatus.contains("未提供 IPO 交易日序号"))
        XCTAssertEqual(live.reconcileReport?.barCount, 1)
        XCTAssertFalse(live.unreadSignals.isEmpty)

        await engine.stop(at: now.addingTimeInterval(3))
        let paused = await engine.state(now: now)
        XCTAssertEqual(paused.phase, .paused)
        let counts = await store.lifecycleCounts()
        XCTAssertEqual(counts.started, 1)
        XCTAssertEqual(counts.ended, 1)
        XCTAssertEqual(counts.checkpoints, 1)
        let before = await provider.count()
        await engine.pollNow(now: now.addingTimeInterval(4))
        let after = await provider.count()
        XCTAssertEqual(before, after)
    }

    func testLiveEnginePersistsSessionTickAndProviderRequestCounts() async throws {
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-11-16T10:00:00+08:00"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("Monitor.sqlite"), appGroupIdentifier: nil)
        try await store.open()
        try await store.setWatchCodes(["600000"])
        let provider = CountingMarketProvider(timestamp: now)
        let engine = LiveEngine(store: store, source: provider, limitSource: nil)
        await engine.start(now: now)
        var live = await engine.state(now: now)
        for _ in 0..<100 {
            if live.latestSnapshot != nil { break }
            try await Task.sleep(for: .milliseconds(10))
            live = await engine.state(now: now)
        }
        XCTAssertNotNil(live.latestSnapshot)
        await engine.stop(at: now.addingTimeInterval(60))
        let usage = try await store.latestSessionUsage()
        XCTAssertEqual(usage, MonitorSessionUsage(tickCount: 1, requestCount: 1))
    }

    func testSQLiteRestoresRulesHoldingsLatestQuotesAndMinuteCursorAndMarksSignalRead() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = directory.appendingPathComponent("Monitor.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: database)
        try await store.open()
        try await store.setWatchCodes(["600000"])
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let rule = WatchRule(id: "r1", code: "600000", title: "价位", detail: "到达",
                             condition: .priceAtLeast(11), sustainedTicks: 2, cooldown: 30)
        let holding = Holding(code: "600000", shares: 100, averageCost: 10.2, updatedAt: timestamp)
        try await store.setRules([rule])
        try await store.setHoldings([holding])
        let quote = Quote(code: "600000", name: "浦发银行", timestamp: timestamp, price: 10.5,
            previousClose: 10.4, open: 10.4, high: 10.6, low: 10.3, volume: 200,
            sourceID: "fixture", retrievedAt: timestamp)
        let index = Quote(code: "000001", name: "上证指数", timestamp: timestamp, price: 3600,
            previousClose: 3590, open: 3590, high: 3610, low: 3580, volume: 1_000,
            sourceID: "fixture", retrievedAt: timestamp, kind: .index)
        try await store.insertQuotes([quote])
        try await store.insertIndexQuotes([index])
        let bar = MinuteBar(code: "600000", name: "浦发银行", timestamp: timestamp.addingTimeInterval(60),
            open: 10.5, close: 10.6, high: 10.7, low: 10.5, volume: 30, amount: 318,
            previousClose: 10.4, sourceID: "fixture-history", fetchedAt: timestamp)
        let signal = AlertSignal(code: "600000", ruleID: "r1", level: .warning,
            title: "测试信号", detail: "补齐产生", createdAt: timestamp)
        try await store.commitReconciliation(bars: [bar], signals: [signal])

        let restored = try await store.restoreState()
        XCTAssertEqual(restored.watchRules, [rule])
        XCTAssertEqual(restored.holdings, [holding])
        XCTAssertEqual(restored.latestQuotes.first?.sourceID, "fixture")
        XCTAssertEqual(restored.latestIndexQuotes.first?.kind, .index)
        XCTAssertEqual(restored.lastQuoteTimeByCode["600000"], timestamp)
        XCTAssertEqual(restored.lastMinuteTimestampByCode["600000"], bar.timestamp)
        XCTAssertEqual(restored.unreadSignals, [signal])
        try await store.markSignalRead(signal.id, at: timestamp.addingTimeInterval(10))
        let afterRead = try await store.restoreState()
        XCTAssertTrue(afterRead.unreadSignals.isEmpty)
        try await store.checkpoint()
    }
}

private actor MemoryMonitorStore: MonitorStore {
    private var restored: RestoredState
    private var starts = 0
    private var ends = 0
    private var checkpointCount = 0

    init(restored: RestoredState) { self.restored = restored }
    func open() async throws {}
    func restoreState() async throws -> RestoredState { restored }
    func setWatchCodes(_ codes: [String]) async throws {
        restored = RestoredState(watchCodes: codes, watchRules: restored.watchRules,
            holdings: restored.holdings, unreadSignals: restored.unreadSignals,
            latestQuotes: restored.latestQuotes, latestIndexQuotes: restored.latestIndexQuotes,
            lastQuoteTime: restored.lastQuoteTime, lastQuoteTimeByCode: restored.lastQuoteTimeByCode,
            lastMinuteTimestampByCode: restored.lastMinuteTimestampByCode)
    }
    func setRules(_ rules: [WatchRule]) async throws {}
    func setHoldings(_ holdings: [Holding]) async throws {}
    func markSignalRead(_ id: UUID, at date: Date) async throws {}
    func insertQuotes(_ quotes: [Quote]) async throws {}
    func insertIndexQuotes(_ quotes: [Quote]) async throws {}
    func appendSignals(_ signals: [AlertSignal]) async throws {}
    func commitReconciliation(bars: [MinuteBar], signals: [AlertSignal]) async throws {}
    func beginSession(at date: Date) async throws { starts += 1 }
    func endSession(at date: Date) async throws { ends += 1 }
    func checkpoint() async throws { checkpointCount += 1 }
    func lifecycleCounts() -> (started: Int, ended: Int, checkpoints: Int) { (starts, ends, checkpointCount) }
}

private actor CountingMarketProvider: MarketDataProviding {
    private let timestamp: Date
    private var calls = 0

    init(timestamp: Date) { self.timestamp = timestamp }
    func fetch(codes: [String], indices: [MarketIndex]) async -> MarketDataBatch {
        calls += 1
        let quotes = codes.map { code in
            Quote(code: code, name: "Fixture", timestamp: timestamp, price: 10.1,
                previousClose: 9.8, open: 10, high: 10.2, low: 9.9, volume: 100,
                sourceID: "fixture", retrievedAt: timestamp, timestampIsProvider: true)
        }
        return MarketDataBatch(quotes: quotes, indexQuotes: [], sourceStatuses: [SourceStatus(
            sourceID: "fixture", fetchedAt: timestamp, providerTimestamp: timestamp,
            requestedCount: codes.count + indices.count, returnedCount: quotes.count, requestCount: 1)])
    }
    func count() -> Int { calls }
}

private struct FixtureHistorySource: HistoricalReconcileSource {
    let bar: MinuteBar
    var identifier: String { "fixture-history" }
    func reconcile(codes: [String], afterByCode: [String: Date]) async -> ReconcileResult {
        let bars = codes.contains(bar.code) ? [bar] : []
        let report = ReconcileReport(sourceID: identifier, requestedCodes: codes,
            reconciledCodes: bars.isEmpty ? [] : [bar.code], skippedCodes: [], barCount: bars.count,
            earliestBar: bars.first?.timestamp, latestBar: bars.last?.timestamp,
            warnings: [], requestCount: 1)
        let status = SourceStatus(sourceID: identifier, fetchedAt: bar.fetchedAt,
            providerTimestamp: bar.timestamp, requestedCount: codes.count,
            returnedCount: bars.count, requestCount: 1)
        return ReconcileResult(bars: bars, report: report, status: status)
    }
}

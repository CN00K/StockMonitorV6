import XCTest
@testable import StockMonitorCore

final class RuleFamilyEngineTests: XCTestCase {
    private let code = "600000"

    private func date(_ text: String) -> Date {
        ISO8601DateFormatter().date(from: text)!
    }

    private func only(_ family: RuleFamily,
                      configure: (inout RuleFamilySettings) -> Void = { _ in }) -> [RuleFamilySettings] {
        RuleFamilySettings.defaults.map { original in
            var value = original
            value.enabled = value.family == family
            if value.family == family { configure(&value) }
            return value
        }
    }

    private func quote(_ code: String = "600000", at time: Date, price: Double,
                       previous: Double = 100, open: Double = 100,
                       high: Double? = nil, low: Double? = nil,
                       kind: QuoteKind = .stock) -> Quote {
        Quote(code: code, name: code == "000001" ? "上证指数" : "测试股", timestamp: time,
            price: price, previousClose: previous, open: open,
            high: high ?? price, low: low ?? price, volume: 10_000,
            amount: price * 10_000, sourceID: "fixture", retrievedAt: time,
            timestampIsProvider: true, kind: kind)
    }

    private func bar(_ time: Date, close: Double = 100, volume: Int64 = 100,
                     amount: Double? = 10_000) -> MinuteBar {
        MinuteBar(code: code, name: "测试股", timestamp: time, open: close, close: close,
            high: close, low: close, volume: volume, amount: amount,
            previousClose: 100, sourceID: "fixture", fetchedAt: time.addingTimeInterval(61))
    }

    func testApprovedDefaultThresholdsForAllFourteenFamilies() throws {
        let defaults = RuleFamilySettings.defaults
        XCTAssertEqual(defaults.count, 14)
        func value(_ family: RuleFamily) throws -> RuleFamilySettings {
            try XCTUnwrap(defaults.first(where: { $0.family == family }))
        }
        XCTAssertEqual(try value(.dailyChange).threshold, 3)
        XCTAssertEqual(try value(.dailyChange).confirmations, 2)
        XCTAssertEqual(try value(.dailyChange).cooldownSeconds, 1_800)
        XCTAssertEqual(try value(.absolutePrice).confirmations, 2)
        XCTAssertEqual(try value(.minuteVolumeSurge).threshold, 2)
        XCTAssertEqual(try value(.minuteVolumeSurge).baselineBars, 5)
        XCTAssertEqual(try value(.minuteVolumeSurge).confirmations, 2)
        XCTAssertEqual(try value(.minuteVolumeSurge).cooldownSeconds, 900)
        XCTAssertEqual(try value(.minuteAmount).threshold, 50_000_000)
        XCTAssertEqual(try value(.minuteAmount).cooldownSeconds, 900)
        XCTAssertEqual(try value(.openingGap).threshold, 2)
        XCTAssertEqual(try value(.movingAverageCross).shortWindowBars, 5)
        XCTAssertEqual(try value(.movingAverageCross).longWindowBars, 20)
        XCTAssertEqual(try value(.movingAverageCross).confirmations, 2)
        XCTAssertEqual(try value(.vwapDeviation).threshold, 1.5)
        XCTAssertEqual(try value(.vwapDeviation).confirmations, 2)
        XCTAssertEqual(try value(.vwapDeviation).cooldownSeconds, 900)
        XCTAssertEqual(try value(.minutePriceSpeed).threshold, 1)
        XCTAssertEqual(try value(.minutePriceSpeed).cooldownSeconds, 600)
        XCTAssertEqual(try value(.drawdownRebound).threshold, 3)
        XCTAssertEqual(try value(.drawdownRebound).cooldownSeconds, 1_800)
        XCTAssertEqual(try value(.relativeStrength).threshold, 2)
        XCTAssertEqual(try value(.relativeStrength).windowSeconds, 1_800)
        XCTAssertEqual(try value(.relativeStrength).confirmations, 2)
        XCTAssertEqual(try value(.relativeStrength).cooldownSeconds, 1_800)
        XCTAssertEqual(try value(.holdingPnL).threshold, 5)
        XCTAssertEqual(try value(.holdingPnL).cooldownSeconds, 1_800)
        XCTAssertEqual(try value(.majorWatchlistEvent).minimumPriority, 3)
        XCTAssertEqual(try value(.sectorEventCluster).minimumIndependentEvents, 3)
        XCTAssertEqual(try value(.sectorEventCluster).minimumSources, 2)
        XCTAssertEqual(try value(.sectorEventCluster).windowSeconds, 3_600)
        XCTAssertEqual(try value(.sectorEventCluster).minimumPriority, 3)
    }

    func testDailyChangeNeedsDistinctProviderSamplesAndCooldown() {
        let start = date("2026-11-16T10:00:00+08:00")
        var engine = RuleFamilyEngine(settings: only(.dailyChange))
        let first = quote(at: start, price: 104)
        XCTAssertTrue(engine.evaluate(current: MarketSnapshot(capturedAt: start, quotes: [first]),
            holdings: [], now: start).isEmpty)
        // A repeated response with the same provider timestamp is not a second confirmation.
        XCTAssertTrue(engine.evaluate(current: MarketSnapshot(capturedAt: start.addingTimeInterval(1), quotes: [first]),
            holdings: [], now: start.addingTimeInterval(1)).isEmpty)
        let secondTime = start.addingTimeInterval(2)
        let second = quote(at: secondTime, price: 104)
        XCTAssertEqual(engine.evaluate(current: MarketSnapshot(capturedAt: secondTime, quotes: [second]),
            holdings: [], now: secondTime).filter { $0.ruleID == RuleFamily.dailyChange.rawValue }.count, 1)
        let insideCooldown = start.addingTimeInterval(120)
        XCTAssertTrue(engine.evaluate(current: MarketSnapshot(capturedAt: insideCooldown,
            quotes: [quote(at: insideCooldown, price: 104)]), holdings: [], now: insideCooldown).isEmpty)
        let afterCooldown = start.addingTimeInterval(1_900)
        XCTAssertEqual(engine.evaluate(current: MarketSnapshot(capturedAt: afterCooldown,
            quotes: [quote(at: afterCooldown, price: 104)]), holdings: [], now: afterCooldown)
            .filter { $0.ruleID == RuleFamily.dailyChange.rawValue }.count, 1)
    }

    func testAbsolutePriceConfirmationAndDailyOpeningGapLimit() {
        let start = date("2026-11-16T10:00:00+08:00")
        var absolute = RuleFamilyEngine(settings: only(.absolutePrice) { settings in
            settings.setAbsoluteHigh(102, for: "600000")
            settings.setAbsoluteLow(98, for: "600000")
        })
        XCTAssertTrue(absolute.evaluate(current: MarketSnapshot(capturedAt: start,
            quotes: [quote(at: start, price: 102)]), holdings: [], now: start).isEmpty)
        let highTime = start.addingTimeInterval(1)
        XCTAssertEqual(absolute.evaluate(current: MarketSnapshot(capturedAt: highTime,
            quotes: [quote(at: highTime, price: 102)]), holdings: [], now: highTime)
            .filter { $0.ruleID == RuleFamily.absolutePrice.rawValue }.count, 1)
        let low1 = start.addingTimeInterval(2)
        XCTAssertTrue(absolute.evaluate(current: MarketSnapshot(capturedAt: low1,
            quotes: [quote(at: low1, price: 97)]), holdings: [], now: low1).isEmpty)
        let low2 = start.addingTimeInterval(3)
        XCTAssertEqual(absolute.evaluate(current: MarketSnapshot(capturedAt: low2,
            quotes: [quote(at: low2, price: 97)]), holdings: [], now: low2)
            .filter { $0.ruleID == RuleFamily.absolutePrice.rawValue }.count, 1)

        var gap = RuleFamilyEngine(settings: only(.openingGap))
        let gapQuote = quote(at: start, price: 102, open: 102)
        XCTAssertEqual(gap.evaluate(current: MarketSnapshot(capturedAt: start, quotes: [gapQuote]),
            holdings: [], now: start).filter { $0.ruleID == RuleFamily.openingGap.rawValue }.count, 1)
        let next = start.addingTimeInterval(2)
        XCTAssertTrue(gap.evaluate(current: MarketSnapshot(capturedAt: next,
            quotes: [quote(at: next, price: 103, open: 102)]), holdings: [], now: next).isEmpty)
    }

    func testSessionBreakoutDrawdownReboundAndHoldingPnL() {
        let start = date("2026-11-16T10:00:00+08:00")
        var breakout = RuleFamilyEngine(settings: only(.sessionBreakout))
        _ = breakout.evaluate(current: MarketSnapshot(capturedAt: start,
            quotes: [quote(at: start, price: 100, high: 100, low: 99)]), holdings: [], now: start)
        let highTime = start.addingTimeInterval(1)
        XCTAssertEqual(breakout.evaluate(current: MarketSnapshot(capturedAt: highTime,
            quotes: [quote(at: highTime, price: 101, high: 101, low: 99.5)]), holdings: [], now: highTime)
            .filter { $0.ruleID == RuleFamily.sessionBreakout.rawValue }.count, 1)
        let nextHigh = start.addingTimeInterval(2)
        XCTAssertTrue(breakout.evaluate(current: MarketSnapshot(capturedAt: nextHigh,
            quotes: [quote(at: nextHigh, price: 102, high: 102, low: 99.5)]), holdings: [], now: nextHigh).isEmpty,
            "A direction is emitted only once per China trade day.")

        var reversal = RuleFamilyEngine(settings: only(.drawdownRebound) { $0.cooldownSeconds = 0 })
        _ = reversal.evaluate(current: MarketSnapshot(capturedAt: start,
            quotes: [quote(at: start, price: 110, high: 110, low: 106)]), holdings: [], now: start)
        let pullback = start.addingTimeInterval(1)
        XCTAssertTrue(reversal.evaluate(current: MarketSnapshot(capturedAt: pullback,
            quotes: [quote(at: pullback, price: 106.5, high: 107, low: 106)]), holdings: [], now: pullback)
            .contains { $0.ruleID == RuleFamily.drawdownRebound.rawValue && $0.title.contains("回撤") })
        let rebound = start.addingTimeInterval(2)
        XCTAssertTrue(reversal.evaluate(current: MarketSnapshot(capturedAt: rebound,
            quotes: [quote(at: rebound, price: 109.3, high: 109.3, low: 108)]), holdings: [], now: rebound)
            .contains { $0.ruleID == RuleFamily.drawdownRebound.rawValue && $0.title.contains("反弹") })

        var pnl = RuleFamilyEngine(settings: only(.holdingPnL))
        let pnlSignals = pnl.evaluate(current: MarketSnapshot(capturedAt: start,
            quotes: [quote(at: start, price: 106)]), holdings: [Holding(code: code, shares: 100, averageCost: 100)], now: start)
        XCTAssertTrue(pnlSignals.contains { $0.ruleID == RuleFamily.holdingPnL.rawValue && $0.title.contains("浮盈") })
    }

    func testMinuteVolumeAmountAndSpeedRulesUseCompleteBars() {
        let start = date("2026-11-16T09:30:00+08:00")
        var volumeEngine = RuleFamilyEngine(settings: only(.minuteVolumeSurge))
        var bars: [MinuteBar] = []
        for minute in 0..<5 { bars.append(bar(start.addingTimeInterval(Double(minute * 60)), volume: 100)) }
        bars.append(bar(start.addingTimeInterval(5 * 60), volume: 201))
        bars.append(bar(start.addingTimeInterval(6 * 60), volume: 600))
        let volumeSignals = volumeEngine.evaluateMinuteBars(bars, now: start.addingTimeInterval(8 * 60))
        XCTAssertTrue(volumeSignals.contains { $0.ruleID == RuleFamily.minuteVolumeSurge.rawValue })

        var amountEngine = RuleFamilyEngine(settings: only(.minuteAmount))
        let amountBar = bar(start, volume: 500_000, amount: 50_000_001)
        XCTAssertTrue(amountEngine.evaluateMinuteBars([amountBar], now: start.addingTimeInterval(2 * 60))
            .contains { $0.ruleID == RuleFamily.minuteAmount.rawValue })

        var speedEngine = RuleFamilyEngine(settings: only(.minutePriceSpeed))
        let speedBars = [bar(start, close: 100), bar(start.addingTimeInterval(60), close: 102)]
        XCTAssertTrue(speedEngine.evaluateMinuteBars(speedBars, now: start.addingTimeInterval(3 * 60))
            .contains { $0.ruleID == RuleFamily.minutePriceSpeed.rawValue })

        var incompleteEngine = RuleFamilyEngine(settings: only(.minuteAmount))
        let incomplete = MinuteBar(code: code, name: "测试股", timestamp: start, open: 100, close: 100,
            high: 100, low: 100, volume: 500_000, amount: 60_000_000, previousClose: 100,
            sourceID: "fixture", fetchedAt: start.addingTimeInterval(20))
        XCTAssertTrue(incompleteEngine.evaluateMinuteBars([incomplete], now: start.addingTimeInterval(2 * 60)).isEmpty)
    }

    func testVwapAndMovingAverageCrossoverNeedConfiguredCompleteBarConfirmations() {
        let start = date("2026-11-16T09:30:00+08:00")
        var vwap = RuleFamilyEngine(settings: only(.vwapDeviation))
        let vwapBars = [
            bar(start, close: 100),
            bar(start.addingTimeInterval(60), close: 100),
            bar(start.addingTimeInterval(120), close: 104),
            bar(start.addingTimeInterval(180), close: 106)
        ]
        XCTAssertTrue(vwap.evaluateMinuteBars(vwapBars, now: start.addingTimeInterval(5 * 60))
            .contains { $0.ruleID == RuleFamily.vwapDeviation.rawValue })

        var movingAverage = RuleFamilyEngine(settings: only(.movingAverageCross))
        var bars: [MinuteBar] = []
        for minute in 0..<20 {
            let close = minute < 15 ? 100.0 : 99.0
            bars.append(bar(start.addingTimeInterval(Double(minute * 60)), close: close))
        }
        bars.append(bar(start.addingTimeInterval(20 * 60), close: 110))
        bars.append(bar(start.addingTimeInterval(21 * 60), close: 111))
        XCTAssertTrue(movingAverage.evaluateMinuteBars(bars, now: start.addingTimeInterval(24 * 60))
            .contains { $0.ruleID == RuleFamily.movingAverageCross.rawValue })
    }

    func testRelativeStrengthUsesThirtyMinuteStockAndShanghaiIndexWindows() {
        let start = date("2026-11-16T09:30:00+08:00")
        var engine = RuleFamilyEngine(settings: only(.relativeStrength))
        var signals: [AlertSignal] = []
        for minute in 0...31 {
            let time = start.addingTimeInterval(Double(minute * 60))
            let stockPrice = minute >= 30 ? 104.0 : 100.0
            let indexPrice = minute >= 30 ? 101.0 : 100.0
            let stock = quote(code, at: time, price: stockPrice)
            let index = quote("000001", at: time, price: indexPrice, kind: .index)
            signals.append(contentsOf: engine.evaluate(current: MarketSnapshot(capturedAt: time,
                quotes: [stock], indexQuotes: [index]), holdings: [], now: time))
        }
        XCTAssertTrue(signals.contains { $0.ruleID == RuleFamily.relativeStrength.rawValue })
    }

    func testQuietHoursMuteSignalsAndThereAreExactlyFourteenFamilies() {
        XCTAssertEqual(RuleFamily.allCases.count, 14)
        var engine = RuleFamilyEngine(settings: only(.dailyChange) { settings in
            settings.confirmations = 1
            settings.quietStartMinute = 9 * 60 + 45
            settings.quietEndMinute = 10 * 60 + 15
        })
        let quiet = date("2026-11-16T10:00:00+08:00")
        XCTAssertTrue(engine.evaluate(current: MarketSnapshot(capturedAt: quiet,
            quotes: [quote(at: quiet, price: 104)]), holdings: [], now: quiet).isEmpty)
        let resumed = date("2026-11-16T10:16:00+08:00")
        XCTAssertTrue(engine.evaluate(current: MarketSnapshot(capturedAt: resumed,
            quotes: [quote(at: resumed, price: 104)]), holdings: [], now: resumed)
            .contains { $0.ruleID == RuleFamily.dailyChange.rawValue })
    }

    func testMajorWatchlistEventDedupAndSectorClusterSourceThreshold() {
        let now = date("2026-11-16T10:00:00+08:00")
        var engine = RuleFamilyEngine(settings: only(.majorWatchlistEvent))
        // Enable sector clustering too; it has separate threshold/configuration semantics.
        var combined = RuleFamilySettings.defaults
        combined = combined.map { value in
            var copy = value
            copy.enabled = value.family == .majorWatchlistEvent || value.family == .sectorEventCluster
            return copy
        }
        engine.replaceSettings(combined)
        let major = MarketEvent(id: "major-1", kind: .announcement, sourceID: "cninfo",
            title: "浦发银行重大公告", publishedAt: now, fetchedAt: now, priority: 3,
            impactScope: .stock, stockCodes: [code])
        let first = engine.evaluateEvents([major], watchCodes: [code], now: now)
        XCTAssertTrue(first.contains { $0.ruleID == RuleFamily.majorWatchlistEvent.rawValue })
        XCTAssertFalse(engine.evaluateEvents([major], watchCodes: [code], now: now.addingTimeInterval(1))
            .contains { $0.ruleID == RuleFamily.majorWatchlistEvent.rawValue })

        let clusterEvents = [
            MarketEvent(id: "sector-1", kind: .news, sourceID: "cls", title: "银行板块事件一",
                publishedAt: now.addingTimeInterval(-1_200), fetchedAt: now, priority: 3,
                impactScope: .sector, sectors: ["银行"]),
            MarketEvent(id: "sector-2", kind: .news, sourceID: "eastmoney", title: "银行板块事件二",
                publishedAt: now.addingTimeInterval(-600), fetchedAt: now, priority: 2,
                impactScope: .sector, sectors: ["银行"]),
            MarketEvent(id: "sector-3", kind: .announcement, sourceID: "gov", title: "银行板块事件三",
                publishedAt: now, fetchedAt: now, priority: 1,
                impactScope: .sector, sectors: ["银行"])
        ]
        let clusterSignals = engine.evaluateEvents(clusterEvents, watchCodes: [], now: now)
        XCTAssertTrue(clusterSignals.contains { $0.ruleID == RuleFamily.sectorEventCluster.rawValue })
        XCTAssertFalse(engine.evaluateEvents(clusterEvents, watchCodes: [], now: now.addingTimeInterval(1))
            .contains { $0.ruleID == RuleFamily.sectorEventCluster.rawValue })
    }

    func testSQLitePersistsRuleFamilySettingsCheckpointAndLiveCommit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let database = directory.appendingPathComponent("Monitor.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: database)
        try await store.open()
        var settings = RuleFamilySettings.defaults
        let dailyIndex = try XCTUnwrap(settings.firstIndex(where: { $0.family == .dailyChange }))
        settings[dailyIndex].threshold = 4.25
        settings[dailyIndex].quietStartMinute = 600
        let time = date("2026-11-16T10:00:00+08:00")
        let checkpoint = RuleFamilyCheckpoint(
            confirmationCounts: ["daily_change|600000|up": 1],
            lastFiredAt: ["daily_change|600000|up": time],
            firedDailyKeys: ["opening_gap|600000|2026-11-16|up"],
            lastEvaluatedQuoteTimestampByKey: ["stock:600000": time])
        let quote = quote(at: time, price: 101)
        let minute = bar(time, close: 101, volume: 100, amount: 10_100)
        let signal = AlertSignal(code: code, ruleID: RuleFamily.dailyChange.rawValue,
            level: .warning, title: "测试", detail: "原子写入", createdAt: time)
        try await store.setRuleFamilySettings(settings)
        try await store.commitLiveEvaluation(quotes: [quote], indexQuotes: [], bars: [minute],
            signals: [signal], ruleCheckpoint: checkpoint)
        let restored = try await store.restoreState()
        XCTAssertEqual(restored.ruleFamilySettings.first(where: { $0.family == .dailyChange })?.threshold, 4.25)
        XCTAssertEqual(restored.ruleFamilySettings.first(where: { $0.family == .dailyChange })?.quietStartMinute, 600)
        XCTAssertEqual(restored.ruleCheckpoint, checkpoint)
        XCTAssertEqual(restored.unreadSignals, [signal])
        XCTAssertEqual(restored.lastQuoteTime, time)
        let restoredBars = try await store.fetchRecentMinuteBars(codes: [code], since: time)
        XCTAssertEqual(restoredBars, [minute])
        try await store.checkpoint()
    }
}

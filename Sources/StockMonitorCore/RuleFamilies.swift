import Foundation

public enum RuleFamily: String, Codable, CaseIterable, Sendable, Hashable, Identifiable {
    case dailyChange = "daily_change"
    case absolutePrice = "absolute_price"
    case minuteVolumeSurge = "minute_volume_surge"
    case minuteAmount = "minute_amount"
    case openingGap = "opening_gap"
    case sessionBreakout = "session_breakout"
    case movingAverageCross = "moving_average_cross"
    case vwapDeviation = "vwap_deviation"
    case minutePriceSpeed = "minute_price_speed"
    case drawdownRebound = "drawdown_rebound"
    case relativeStrength = "relative_strength"
    case holdingPnL = "holding_pnl"
    case majorWatchlistEvent = "major_watchlist_event"
    case sectorEventCluster = "sector_event_cluster"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .dailyChange: return "单日涨跌幅阈值"
        case .absolutePrice: return "绝对价格高/低位"
        case .minuteVolumeSurge: return "分钟量能突增"
        case .minuteAmount: return "单分钟成交额"
        case .openingGap: return "开盘跳空"
        case .sessionBreakout: return "盘中高点/低点突破"
        case .movingAverageCross: return "5/20 分钟均线交叉"
        case .vwapDeviation: return "VWAP 偏离"
        case .minutePriceSpeed: return "一分钟价格速度"
        case .drawdownRebound: return "盘中回撤/反弹"
        case .relativeStrength: return "相对上证综指强弱"
        case .holdingPnL: return "持仓浮盈/浮亏"
        case .majorWatchlistEvent: return "自选股重大资讯"
        case .sectorEventCluster: return "板块事件聚集"
        }
    }

    public var thresholdLabel: String {
        switch self {
        case .dailyChange: return "涨跌幅阈值 (%)"
        case .absolutePrice: return "各自选股高/低价 (CNY)"
        case .minuteVolumeSurge: return "对比此前完整分钟均量 (倍)"
        case .minuteAmount: return "成交额阈值 (CNY)"
        case .openingGap: return "开盘跳空阈值 (%)"
        case .sessionBreakout: return "阈值由本地观察高/低点决定"
        case .movingAverageCross: return "短/长均线窗口 (分钟)"
        case .vwapDeviation: return "VWAP 偏离阈值 (%)"
        case .minutePriceSpeed: return "一分钟变化阈值 (%)"
        case .drawdownRebound: return "回撤/反弹阈值 (%)"
        case .relativeStrength: return "相对收益差阈值 (百分点)"
        case .holdingPnL: return "成本浮盈/浮亏阈值 (%)"
        case .majorWatchlistEvent: return "最低来源优先级 (P1–P5)"
        case .sectorEventCluster: return "独立事件最少条数"
        }
    }
}

/// One editable, locally persisted configuration per rule family. `threshold` is
/// interpreted according to `family`; absolute-price limits are stored per code.
public struct RuleFamilySettings: Codable, Sendable, Equatable, Identifiable {
    public let family: RuleFamily
    public var enabled: Bool
    public var threshold: Double
    public var confirmations: Int
    public var cooldownSeconds: TimeInterval
    public var baselineBars: Int
    public var shortWindowBars: Int
    public var longWindowBars: Int
    public var windowSeconds: TimeInterval
    public var minimumIndependentEvents: Int
    public var minimumSources: Int
    public var minimumPriority: Int
    public var absoluteHighByCode: [String: Double]
    public var absoluteLowByCode: [String: Double]
    public var sessionOnly: Bool
    /// China-time minutes after midnight. If both are set, the half-open interval
    /// [start,end) is muted; start > end represents an overnight quiet interval.
    public var quietStartMinute: Int?
    public var quietEndMinute: Int?

    public var id: String { family.rawValue }

    public init(family: RuleFamily, enabled: Bool = true, threshold: Double,
                confirmations: Int, cooldownSeconds: TimeInterval,
                baselineBars: Int = 5, shortWindowBars: Int = 5, longWindowBars: Int = 20,
                windowSeconds: TimeInterval = 1_800, minimumIndependentEvents: Int = 3,
                minimumSources: Int = 2, minimumPriority: Int = 3,
                absoluteHighByCode: [String: Double] = [:], absoluteLowByCode: [String: Double] = [:],
                sessionOnly: Bool = true, quietStartMinute: Int? = nil, quietEndMinute: Int? = nil) {
        self.family = family
        self.enabled = enabled
        self.threshold = threshold.isFinite ? max(0, threshold) : 0
        self.confirmations = min(20, max(1, confirmations))
        self.cooldownSeconds = cooldownSeconds.isFinite ? max(0, cooldownSeconds) : 0
        self.baselineBars = min(60, max(1, baselineBars))
        self.shortWindowBars = min(60, max(1, shortWindowBars))
        self.longWindowBars = min(120, max(self.shortWindowBars + 1, longWindowBars))
        self.windowSeconds = windowSeconds.isFinite ? max(60, windowSeconds) : 1_800
        self.minimumIndependentEvents = min(100, max(1, minimumIndependentEvents))
        self.minimumSources = min(20, max(1, minimumSources))
        self.minimumPriority = min(5, max(1, minimumPriority))
        self.absoluteHighByCode = Self.validPriceMap(absoluteHighByCode)
        self.absoluteLowByCode = Self.validPriceMap(absoluteLowByCode)
        self.sessionOnly = sessionOnly
        self.quietStartMinute = quietStartMinute.map { min(1_439, max(0, $0)) }
        self.quietEndMinute = quietEndMinute.map { min(1_439, max(0, $0)) }
    }

    public static var defaults: [RuleFamilySettings] {
        [
            .init(family: .dailyChange, threshold: 3, confirmations: 2, cooldownSeconds: 30 * 60),
            .init(family: .absolutePrice, threshold: 0, confirmations: 2, cooldownSeconds: 0),
            .init(family: .minuteVolumeSurge, threshold: 2, confirmations: 2, cooldownSeconds: 15 * 60, baselineBars: 5),
            .init(family: .minuteAmount, threshold: 50_000_000, confirmations: 1, cooldownSeconds: 15 * 60),
            .init(family: .openingGap, threshold: 2, confirmations: 1, cooldownSeconds: 0),
            .init(family: .sessionBreakout, threshold: 0, confirmations: 1, cooldownSeconds: 0),
            .init(family: .movingAverageCross, threshold: 0, confirmations: 2, cooldownSeconds: 0, shortWindowBars: 5, longWindowBars: 20),
            .init(family: .vwapDeviation, threshold: 1.5, confirmations: 2, cooldownSeconds: 15 * 60),
            .init(family: .minutePriceSpeed, threshold: 1, confirmations: 1, cooldownSeconds: 10 * 60),
            .init(family: .drawdownRebound, threshold: 3, confirmations: 1, cooldownSeconds: 30 * 60),
            .init(family: .relativeStrength, threshold: 2, confirmations: 2, cooldownSeconds: 30 * 60, windowSeconds: 30 * 60),
            .init(family: .holdingPnL, threshold: 5, confirmations: 1, cooldownSeconds: 30 * 60),
            .init(family: .majorWatchlistEvent, threshold: 3, confirmations: 1, cooldownSeconds: 0, sessionOnly: false),
            .init(family: .sectorEventCluster, threshold: 3, confirmations: 1, cooldownSeconds: 0,
                  windowSeconds: 60 * 60, minimumIndependentEvents: 3, minimumSources: 2,
                  minimumPriority: 3, sessionOnly: false)
        ]
    }

    public static func defaultsByFamily() -> [RuleFamily: RuleFamilySettings] {
        Dictionary(uniqueKeysWithValues: defaults.map { ($0.family, $0) })
    }

    public mutating func setAbsoluteHigh(_ value: Double?, for code: String) {
        if let value, value.isFinite, value > 0 { absoluteHighByCode[code] = value }
        else { absoluteHighByCode.removeValue(forKey: code) }
    }

    public mutating func setAbsoluteLow(_ value: Double?, for code: String) {
        if let value, value.isFinite, value > 0 { absoluteLowByCode[code] = value }
        else { absoluteLowByCode.removeValue(forKey: code) }
    }

    private static func validPriceMap(_ values: [String: Double]) -> [String: Double] {
        values.filter { $0.key.range(of: "^[0-9]{6}$", options: .regularExpression) != nil && $0.value.isFinite && $0.value > 0 }
    }
}

public struct MinuteQuoteBucket: Codable, Sendable, Equatable {
    public let minuteStart: Date
    public var first: Quote
    public var last: Quote
    public var high: Double
    public var low: Double

    public init(quote: Quote) {
        let minute = floor(quote.timestamp.timeIntervalSince1970 / 60) * 60
        minuteStart = Date(timeIntervalSince1970: minute)
        first = quote
        last = quote
        high = quote.price
        low = quote.price
    }

    public mutating func append(_ quote: Quote) {
        if quote.timestamp < first.timestamp { first = quote }
        if quote.timestamp >= last.timestamp { last = quote }
        high = max(high, quote.price)
        low = min(low, quote.price)
    }
}

/// All mutable evaluator data is persisted as a bounded JSON checkpoint in SQLite.
public struct RuleFamilyCheckpoint: Codable, Sendable, Equatable {
    public var confirmationCounts: [String: Int]
    public var lastFiredAt: [String: Date]
    public var firedDailyKeys: Set<String>
    public var quoteHistoryByKey: [String: [Quote]]
    public var lastEvaluatedQuoteTimestampByKey: [String: Date]
    public var quoteMinuteBucketsByCode: [String: [MinuteQuoteBucket]]
    public var recentBarsByCode: [String: [MinuteBar]]
    public var sessionDayByCode: [String: String]
    public var observedHighByCode: [String: Double]
    public var observedLowByCode: [String: Double]
    public var vwapVolumeByCode: [String: Double]
    public var vwapAmountByCode: [String: Double]
    public var smaSignByCode: [String: Int]
    public var smaCandidateDirectionByCode: [String: Int]
    public var smaCandidateCountByCode: [String: Int]
    public var lastRelativeMinuteByCode: [String: Date]
    public var processedEventIDs: Set<String>
    public var recentSectorEvents: [MarketEvent]
    public var firedSectorClusterKeys: Set<String>

    public init(confirmationCounts: [String: Int] = [:], lastFiredAt: [String: Date] = [:],
                firedDailyKeys: Set<String> = [], quoteHistoryByKey: [String: [Quote]] = [:],
                lastEvaluatedQuoteTimestampByKey: [String: Date] = [:],
                quoteMinuteBucketsByCode: [String: [MinuteQuoteBucket]] = [:],
                recentBarsByCode: [String: [MinuteBar]] = [:], sessionDayByCode: [String: String] = [:],
                observedHighByCode: [String: Double] = [:], observedLowByCode: [String: Double] = [:],
                vwapVolumeByCode: [String: Double] = [:], vwapAmountByCode: [String: Double] = [:],
                smaSignByCode: [String: Int] = [:], smaCandidateDirectionByCode: [String: Int] = [:],
                smaCandidateCountByCode: [String: Int] = [:], lastRelativeMinuteByCode: [String: Date] = [:],
                processedEventIDs: Set<String> = [], recentSectorEvents: [MarketEvent] = [],
                firedSectorClusterKeys: Set<String> = []) {
        self.confirmationCounts = confirmationCounts
        self.lastFiredAt = lastFiredAt
        self.firedDailyKeys = firedDailyKeys
        self.quoteHistoryByKey = quoteHistoryByKey
        self.lastEvaluatedQuoteTimestampByKey = lastEvaluatedQuoteTimestampByKey
        self.quoteMinuteBucketsByCode = quoteMinuteBucketsByCode
        self.recentBarsByCode = recentBarsByCode
        self.sessionDayByCode = sessionDayByCode
        self.observedHighByCode = observedHighByCode
        self.observedLowByCode = observedLowByCode
        self.vwapVolumeByCode = vwapVolumeByCode
        self.vwapAmountByCode = vwapAmountByCode
        self.smaSignByCode = smaSignByCode
        self.smaCandidateDirectionByCode = smaCandidateDirectionByCode
        self.smaCandidateCountByCode = smaCandidateCountByCode
        self.lastRelativeMinuteByCode = lastRelativeMinuteByCode
        self.processedEventIDs = processedEventIDs
        self.recentSectorEvents = recentSectorEvents
        self.firedSectorClusterKeys = firedSectorClusterKeys
    }
}

public struct RuleFamilyEvaluation: Sendable {
    public let signals: [AlertSignal]
    public let completedBars: [MinuteBar]

    public init(signals: [AlertSignal], completedBars: [MinuteBar]) {
        self.signals = signals
        self.completedBars = completedBars
    }
}

/// Deterministic local evaluator for the 14 approved rule families.
public struct RuleFamilyEngine: Sendable {
    private var settingsByFamily: [RuleFamily: RuleFamilySettings]
    private var state: RuleFamilyCheckpoint

    public init(settings: [RuleFamilySettings] = RuleFamilySettings.defaults,
                checkpoint: RuleFamilyCheckpoint = RuleFamilyCheckpoint()) {
        self.settingsByFamily = RuleFamilySettings.defaultsByFamily()
        for setting in settings { self.settingsByFamily[setting.family] = setting }
        self.state = checkpoint
    }

    public var settings: [RuleFamilySettings] {
        RuleFamily.allCases.compactMap { settingsByFamily[$0] }
    }

    public var checkpoint: RuleFamilyCheckpoint { state }

    public mutating func replaceSettings(_ settings: [RuleFamilySettings]) {
        var replacement = RuleFamilySettings.defaultsByFamily()
        for setting in settings { replacement[setting.family] = setting }
        settingsByFamily = replacement
    }

    public mutating func restoreCheckpoint(_ checkpoint: RuleFamilyCheckpoint) { state = checkpoint }

    /// Seeds retained local bars silently, so indicator windows survive restart without
    /// replaying old alerts. Current-day filtering is applied by the caller.
    public mutating func seedMinuteBars(_ bars: [MinuteBar]) {
        for code in Set(bars.map(\.code)) {
            state.recentBarsByCode[code] = []
            state.vwapVolumeByCode[code] = 0
            state.vwapAmountByCode[code] = 0
        }
        for bar in bars.sorted(by: { $0.timestamp < $1.timestamp }) where bar.isComplete {
            _ = remember(bar, updateVWAP: true)
        }
    }

    public mutating func seedQuoteHistory(_ quotes: [Quote], now: Date) {
        recordQuoteHistory(quotes, now: now)
    }

    /// Uses provider-timestamped quote samples for quote rules and builds a minute bar
    /// only when cumulative-volume observations bracket its full minute near both edges.
    public mutating func evaluateDetailed(current: MarketSnapshot, holdings: [Holding], now: Date) -> RuleFamilyEvaluation {
        let incomingStocks = current.quotes.filter { $0.kind == .stock && $0.timestampIsProvider && $0.price.isFinite }
        let incomingIndices = current.indexQuotes.filter { $0.kind == .index && $0.timestampIsProvider && $0.price.isFinite }
        let quotes = incomingStocks.filter { $0.timestamp > state.lastEvaluatedQuoteTimestampByKey[Self.quoteHistoryKey($0), default: .distantPast] }
        let indices = incomingIndices.filter { $0.timestamp > state.lastEvaluatedQuoteTimestampByKey[Self.quoteHistoryKey($0), default: .distantPast] }
        for quote in quotes + indices { state.lastEvaluatedQuoteTimestampByKey[Self.quoteHistoryKey(quote)] = quote.timestamp }
        recordQuoteHistory(quotes + indices, now: now)
        let builtBars = makeCompleteBars(quotes, now: now)
        var signals: [AlertSignal] = []
        for quote in quotes.sorted(by: { $0.code < $1.code }) {
            resetDailyStateIfNeeded(code: quote.code, at: quote.timestamp)
            signals.append(contentsOf: evaluateQuote(quote, holdings: holdings, now: now))
        }
        signals.append(contentsOf: evaluateRelativeStrength(quotes: quotes, indices: indices, now: now))
        signals.append(contentsOf: evaluateMinuteBars(builtBars, now: now))
        pruneState(now: now)
        return RuleFamilyEvaluation(signals: signals, completedBars: builtBars)
    }

    public mutating func evaluate(current: MarketSnapshot, holdings: [Holding], now: Date) -> [AlertSignal] {
        evaluateDetailed(current: current, holdings: holdings, now: now).signals
    }

    public mutating func evaluateMinuteBars(_ bars: [MinuteBar], now: Date) -> [AlertSignal] {
        var signals: [AlertSignal] = []
        for bar in bars.sorted(by: {
            if $0.timestamp == $1.timestamp { return $0.code < $1.code }
            return $0.timestamp < $1.timestamp
        }) {
            guard bar.isComplete, Self.sameChinaDay(bar.timestamp, now) else { continue }
            resetDailyStateIfNeeded(code: bar.code, at: bar.timestamp)
            let previousBars = state.recentBarsByCode[bar.code, default: []]
                .filter { Self.sameChinaDay($0.timestamp, bar.timestamp) }
                .sorted { $0.timestamp < $1.timestamp }
            guard !previousBars.contains(where: { $0.id == bar.id }) else { continue }
            signals.append(contentsOf: evaluateBar(bar, previousBars: previousBars, now: bar.timestamp.addingTimeInterval(60)))
            _ = remember(bar, updateVWAP: true)
        }
        pruneState(now: now)
        return signals
    }

    public mutating func evaluateEvents(_ events: [MarketEvent], watchCodes: [String], now: Date) -> [AlertSignal] {
        var signals: [AlertSignal] = []
        let watch = Set(watchCodes)
        let major = settingsByFamily[.majorWatchlistEvent] ?? RuleFamilySettings.defaultsByFamily()[.majorWatchlistEvent]!
        if allowed(major, at: now) {
            for event in events.sorted(by: { eventTime($0) < eventTime($1) }) {
                guard major.enabled, (event.kind == .news || event.kind == .announcement),
                      event.priority >= major.minimumPriority else { continue }
                let matched = event.stockCodes.filter { watch.contains($0) }.sorted()
                guard let code = matched.first, state.processedEventIDs.insert(event.id).inserted else { continue }
                signals.append(AlertSignal(code: code, ruleID: RuleFamily.majorWatchlistEvent.rawValue,
                    level: event.priority >= 4 ? .urgent : .warning,
                    title: "自选股重大资讯：\(event.title)",
                    detail: "\(code) · P\(6 - event.priority) · \(event.corroboratingSources.joined(separator: ", "))\(event.url.map { " · \($0)" } ?? "")",
                    createdAt: now))
            }
        }

        let clusterSettings = settingsByFamily[.sectorEventCluster] ?? RuleFamilySettings.defaultsByFamily()[.sectorEventCluster]!
        if allowed(clusterSettings, at: now) {
            let cutoff = now.addingTimeInterval(-clusterSettings.windowSeconds)
            for event in events where event.kind == .news || event.kind == .announcement {
                let date = eventTime(event)
                guard date >= cutoff && date <= now.addingTimeInterval(60) else { continue }
                if !state.recentSectorEvents.contains(where: { $0.id == event.id }) {
                    state.recentSectorEvents.append(event)
                }
            }
            state.recentSectorEvents = Array(Dictionary(state.recentSectorEvents.map { ($0.id, $0) },
                uniquingKeysWith: { old, new in new.fetchedAt >= old.fetchedAt ? new : old }).values)
                .filter { eventTime($0) >= cutoff && eventTime($0) <= now.addingTimeInterval(60) }
                .sorted { eventTime($0) < eventTime($1) }
            if clusterSettings.enabled {
                signals.append(contentsOf: evaluateSectorClusters(clusterSettings, now: now))
            }
        }
        pruneState(now: now)
        return signals
    }

    private mutating func evaluateQuote(_ quote: Quote, holdings: [Holding], now: Date) -> [AlertSignal] {
        var result: [AlertSignal] = []
        let code = quote.code

        let daily = setting(.dailyChange)
        if allowed(daily, at: now) {
            let up = quote.changePercent >= daily.threshold
            let down = quote.changePercent <= -daily.threshold
            if confirmed(.dailyChange, code: code, direction: "up", matches: up, required: daily.confirmations),
               let signal = fire(.dailyChange, code: code, direction: "up", daily: false, settings: daily,
                    level: .warning, title: "日涨幅达到阈值", detail: String(format: "涨幅 %.2f%%，阈值 +%.2f%%", quote.changePercent, daily.threshold), at: now) { result.append(signal) }
            if confirmed(.dailyChange, code: code, direction: "down", matches: down, required: daily.confirmations),
               let signal = fire(.dailyChange, code: code, direction: "down", daily: false, settings: daily,
                    level: .warning, title: "日跌幅达到阈值", detail: String(format: "跌幅 %.2f%%，阈值 −%.2f%%", quote.changePercent, daily.threshold), at: now) { result.append(signal) }
        }

        let absolute = setting(.absolutePrice)
        if allowed(absolute, at: now) {
            if let high = absolute.absoluteHighByCode[code],
               confirmed(.absolutePrice, code: code, direction: "up", matches: quote.price >= high, required: absolute.confirmations),
               let signal = fire(.absolutePrice, code: code, direction: "up", daily: false, settings: absolute,
                    level: .warning, title: "达到自设高价", detail: String(format: "现价 %.3f ≥ 高价 %.3f CNY", quote.price, high), at: now) { result.append(signal) }
            if let low = absolute.absoluteLowByCode[code],
               confirmed(.absolutePrice, code: code, direction: "down", matches: quote.price <= low, required: absolute.confirmations),
               let signal = fire(.absolutePrice, code: code, direction: "down", daily: false, settings: absolute,
                    level: .warning, title: "达到自设低价", detail: String(format: "现价 %.3f ≤ 低价 %.3f CNY", quote.price, low), at: now) { result.append(signal) }
        }

        let gap = setting(.openingGap)
        if allowed(gap, at: now), quote.previousClose > 0, quote.open > 0 {
            let gapPercent = (quote.open / quote.previousClose - 1) * 100
            if gapPercent >= gap.threshold,
               let signal = fire(.openingGap, code: code, direction: "up", daily: true, settings: gap,
                    level: .warning, title: "开盘向上跳空", detail: String(format: "开盘相对前收 +%.2f%%", gapPercent), at: now) { result.append(signal) }
            if gapPercent <= -gap.threshold,
               let signal = fire(.openingGap, code: code, direction: "down", daily: true, settings: gap,
                    level: .warning, title: "开盘向下跳空", detail: String(format: "开盘相对前收 %.2f%%", gapPercent), at: now) { result.append(signal) }
        }

        let breakout = setting(.sessionBreakout)
        let oldHigh = state.observedHighByCode[code]
        let oldLow = state.observedLowByCode[code]
        state.observedHighByCode[code] = max(oldHigh ?? quote.high, quote.high)
        state.observedLowByCode[code] = min(oldLow ?? quote.low, quote.low)
        if allowed(breakout, at: now), let oldHigh, quote.high > oldHigh + 1e-8,
           let signal = fire(.sessionBreakout, code: code, direction: "up", daily: true, settings: breakout,
                level: .info, title: "刷新本会话已观测高点", detail: String(format: "盘中高点 %.3f", quote.high), at: now) { result.append(signal) }
        if allowed(breakout, at: now), let oldLow, quote.low < oldLow - 1e-8,
           let signal = fire(.sessionBreakout, code: code, direction: "down", daily: true, settings: breakout,
                level: .info, title: "刷新本会话已观测低点", detail: String(format: "盘中低点 %.3f", quote.low), at: now) { result.append(signal) }

        let retrace = setting(.drawdownRebound)
        if allowed(retrace, at: now), let high = state.observedHighByCode[code], high > 0,
           (high - quote.price) / high * 100 >= retrace.threshold,
           let signal = fire(.drawdownRebound, code: code, direction: "down", daily: false, settings: retrace,
                level: .warning, title: "从本会话高点回撤", detail: String(format: "较已观测高点 %.3f 回撤 %.2f%%", high, (high - quote.price) / high * 100), at: now) { result.append(signal) }
        if allowed(retrace, at: now), let low = state.observedLowByCode[code], low > 0,
           (quote.price - low) / low * 100 >= retrace.threshold,
           let signal = fire(.drawdownRebound, code: code, direction: "up", daily: false, settings: retrace,
                level: .warning, title: "从本会话低点反弹", detail: String(format: "较已观测低点 %.3f 反弹 %.2f%%", low, (quote.price - low) / low * 100), at: now) { result.append(signal) }

        let pnl = setting(.holdingPnL)
        if allowed(pnl, at: now), let holding = holdings.first(where: { $0.code == code }), holding.averageCost > 0 {
            let returnPercent = (quote.price / holding.averageCost - 1) * 100
            if returnPercent >= pnl.threshold,
               let signal = fire(.holdingPnL, code: code, direction: "up", daily: false, settings: pnl,
                    level: .warning, title: "持仓浮盈达到阈值", detail: String(format: "成本 %.3f，浮盈 %.2f%%", holding.averageCost, returnPercent), at: now) { result.append(signal) }
            if returnPercent <= -pnl.threshold,
               let signal = fire(.holdingPnL, code: code, direction: "down", daily: false, settings: pnl,
                    level: .warning, title: "持仓浮亏达到阈值", detail: String(format: "成本 %.3f，浮亏 %.2f%%", holding.averageCost, returnPercent), at: now) { result.append(signal) }
        }
        return result
    }

    private mutating func evaluateRelativeStrength(quotes: [Quote], indices: [Quote], now: Date) -> [AlertSignal] {
        let configuration = setting(.relativeStrength)
        guard allowed(configuration, at: now), configuration.enabled,
              let index = indices.first(where: { $0.code == "000001" }) else { return [] }
        var result: [AlertSignal] = []
        let currentMinute = Self.minuteStart(now)
        let indexHistory = state.quoteHistoryByKey[Self.quoteHistoryKey(index), default: []]
        guard let indexBase = indexHistory.last(where: { $0.timestamp <= index.timestamp.addingTimeInterval(-configuration.windowSeconds) }),
              indexBase.price > 0,
              abs(index.timestamp.timeIntervalSince(indexBase.timestamp) - configuration.windowSeconds) <= 120 else { return [] }
        for quote in quotes {
            guard quote.previousClose > 0 else { continue }
            let relativeKey = quote.code
            if state.lastRelativeMinuteByCode[relativeKey] == currentMinute { continue }
            let history = state.quoteHistoryByKey[Self.quoteHistoryKey(quote), default: []]
            guard let base = history.last(where: { $0.timestamp <= quote.timestamp.addingTimeInterval(-configuration.windowSeconds) }),
                  base.price > 0,
                  abs(quote.timestamp.timeIntervalSince(base.timestamp) - configuration.windowSeconds) <= 120 else { continue }
            let stockReturn = (quote.price / base.price - 1) * 100
            let indexReturn = (index.price / indexBase.price - 1) * 100
            let relative = stockReturn - indexReturn
            let up = relative >= configuration.threshold
            let down = relative <= -configuration.threshold
            let direction = up ? "up" : down ? "down" : "none"
            state.lastRelativeMinuteByCode[relativeKey] = currentMinute
            if confirmed(.relativeStrength, code: quote.code, direction: "up", matches: up, required: configuration.confirmations),
               let signal = fire(.relativeStrength, code: quote.code, direction: "up", daily: false, settings: configuration,
                    level: .warning, title: "跑赢上证综指", detail: String(format: "近 30 分钟相对收益差 +%.2f 个百分点", relative), at: now) { result.append(signal) }
            if confirmed(.relativeStrength, code: quote.code, direction: "down", matches: down, required: configuration.confirmations),
               let signal = fire(.relativeStrength, code: quote.code, direction: "down", daily: false, settings: configuration,
                    level: .warning, title: "跑输上证综指", detail: String(format: "近 30 分钟相对收益差 %.2f 个百分点", relative), at: now) { result.append(signal) }
            if !up && !down {
                _ = confirmed(.relativeStrength, code: quote.code, direction: "up", matches: false, required: configuration.confirmations)
                _ = confirmed(.relativeStrength, code: quote.code, direction: "down", matches: false, required: configuration.confirmations)
            }
            _ = direction
        }
        return result
    }

    private mutating func evaluateBar(_ bar: MinuteBar, previousBars: [MinuteBar], now: Date) -> [AlertSignal] {
        var result: [AlertSignal] = []
        let code = bar.code
        let contiguousPrior = previousBars.filter { $0.isComplete }

        let volumeSettings = setting(.minuteVolumeSurge)
        if allowed(volumeSettings, at: now), contiguousPrior.count >= volumeSettings.baselineBars {
            let baseline = contiguousPrior.suffix(volumeSettings.baselineBars).map { Double($0.volume) }
            let mean = baseline.reduce(0, +) / Double(baseline.count)
            let matches = mean > 0 && Double(bar.volume) >= mean * volumeSettings.threshold
            if confirmed(.minuteVolumeSurge, code: code, direction: "any", matches: matches, required: volumeSettings.confirmations),
               let signal = fire(.minuteVolumeSurge, code: code, direction: "any", daily: false, settings: volumeSettings,
                    level: .warning, title: "分钟成交量突增", detail: String(format: "本分钟量 %.0f，为此前 %d 根完整分钟均量的 %.2f 倍", Double(bar.volume), volumeSettings.baselineBars, mean > 0 ? Double(bar.volume) / mean : 0), at: now) { result.append(signal) }
        } else { _ = confirmed(.minuteVolumeSurge, code: code, direction: "any", matches: false, required: volumeSettings.confirmations) }

        let amountSettings = setting(.minuteAmount)
        if allowed(amountSettings, at: now), let amount = bar.amount, amount >= amountSettings.threshold,
           let signal = fire(.minuteAmount, code: code, direction: "any", daily: false, settings: amountSettings,
                level: .warning, title: "单分钟成交额达到阈值", detail: String(format: "本分钟成交额 ¥%.0f", amount), at: now) { result.append(signal) }

        let speedSettings = setting(.minutePriceSpeed)
        if allowed(speedSettings, at: now), let previous = contiguousPrior.last, previous.close > 0,
           previous.timestamp.addingTimeInterval(60) == bar.timestamp {
            let speed = (bar.close / previous.close - 1) * 100
            let up = speed >= speedSettings.threshold
            let down = speed <= -speedSettings.threshold
            if confirmed(.minutePriceSpeed, code: code, direction: "up", matches: up, required: speedSettings.confirmations),
               let signal = fire(.minutePriceSpeed, code: code, direction: "up", daily: false, settings: speedSettings,
                    level: .warning, title: "一分钟快速上涨", detail: String(format: "完整分钟涨幅 +%.2f%%", speed), at: now) { result.append(signal) }
            if confirmed(.minutePriceSpeed, code: code, direction: "down", matches: down, required: speedSettings.confirmations),
               let signal = fire(.minutePriceSpeed, code: code, direction: "down", daily: false, settings: speedSettings,
                    level: .warning, title: "一分钟快速下跌", detail: String(format: "完整分钟涨幅 %.2f%%", speed), at: now) { result.append(signal) }
        } else {
            _ = confirmed(.minutePriceSpeed, code: code, direction: "up", matches: false, required: speedSettings.confirmations)
            _ = confirmed(.minutePriceSpeed, code: code, direction: "down", matches: false, required: speedSettings.confirmations)
        }

        let barsThroughNow = (previousBars + [bar]).suffix(max(120, setting(.movingAverageCross).longWindowBars))
        let maSettings = setting(.movingAverageCross)
        if allowed(maSettings, at: now), barsThroughNow.count >= maSettings.longWindowBars,
           Self.areContiguous(Array(barsThroughNow.suffix(maSettings.longWindowBars))) {
            let values = Array(barsThroughNow.suffix(maSettings.longWindowBars)).map { $0.close }
            let shortMean = values.suffix(maSettings.shortWindowBars).reduce(0, +) / Double(maSettings.shortWindowBars)
            let longMean = values.reduce(0, +) / Double(maSettings.longWindowBars)
            let sign = shortMean > longMean ? 1 : shortMean < longMean ? -1 : 0
            let previousSign = state.smaSignByCode[code]
            if let previousSign, sign != 0, sign != previousSign {
                state.smaCandidateDirectionByCode[code] = sign
                state.smaCandidateCountByCode[code] = 1
            } else if sign != 0, state.smaCandidateDirectionByCode[code] == sign {
                state.smaCandidateCountByCode[code, default: 0] += 1
            } else if sign == 0 {
                state.smaCandidateDirectionByCode[code] = 0
                state.smaCandidateCountByCode[code] = 0
            }
            state.smaSignByCode[code] = sign
            let candidateCount = state.smaCandidateCountByCode[code, default: 0]
            if sign != 0, candidateCount >= maSettings.confirmations {
                let direction = sign > 0 ? "up" : "down"
                if let signal = fire(.movingAverageCross, code: code, direction: direction, daily: true,
                    settings: maSettings, level: .warning,
                    title: sign > 0 ? "5/20 分钟均线金叉" : "5/20 分钟均线死叉",
                    detail: String(format: "5 分钟 SMA %.3f，20 分钟 SMA %.3f，已由 %d 根完整 bar 确认", shortMean, longMean, maSettings.confirmations), at: now) {
                    result.append(signal)
                }
                state.smaCandidateCountByCode[code] = 0
            }
        }

        let vwapSettings = setting(.vwapDeviation)
        if allowed(vwapSettings, at: now), let amount = bar.amount, amount >= 0, bar.volume > 0 {
            let amountTotal = state.vwapAmountByCode[code, default: 0]
            let volumeTotal = state.vwapVolumeByCode[code, default: 0]
            let combinedVolume = volumeTotal + Double(bar.volume)
            let vwap = combinedVolume > 0 ? (amountTotal + amount) / combinedVolume : 0
            let deviation = vwap > 0 ? (bar.close / vwap - 1) * 100 : 0
            let up = vwap > 0 && deviation >= vwapSettings.threshold
            let down = vwap > 0 && deviation <= -vwapSettings.threshold
            if confirmed(.vwapDeviation, code: code, direction: "up", matches: up, required: vwapSettings.confirmations),
               let signal = fire(.vwapDeviation, code: code, direction: "up", daily: false, settings: vwapSettings,
                    level: .warning, title: "价格高于 VWAP", detail: String(format: "价格较本地成交量加权均价高 %.2f%%", deviation), at: now) { result.append(signal) }
            if confirmed(.vwapDeviation, code: code, direction: "down", matches: down, required: vwapSettings.confirmations),
               let signal = fire(.vwapDeviation, code: code, direction: "down", daily: false, settings: vwapSettings,
                    level: .warning, title: "价格低于 VWAP", detail: String(format: "价格较本地成交量加权均价低 %.2f%%", deviation), at: now) { result.append(signal) }
            if !up && !down {
                _ = confirmed(.vwapDeviation, code: code, direction: "up", matches: false, required: vwapSettings.confirmations)
                _ = confirmed(.vwapDeviation, code: code, direction: "down", matches: false, required: vwapSettings.confirmations)
            }
        } else {
            _ = confirmed(.vwapDeviation, code: code, direction: "up", matches: false, required: vwapSettings.confirmations)
            _ = confirmed(.vwapDeviation, code: code, direction: "down", matches: false, required: vwapSettings.confirmations)
        }
        return result
    }

    private mutating func evaluateSectorClusters(_ configuration: RuleFamilySettings, now: Date) -> [AlertSignal] {
        let bySector = Dictionary(grouping: state.recentSectorEvents.flatMap { event in
            event.sectors.map { ($0, event) }
        }, by: { $0.0 })
        var result: [AlertSignal] = []
        for sector in bySector.keys.sorted() {
            let events = (bySector[sector] ?? []).map(\.1).sorted { eventTime($0) < eventTime($1) }
            guard events.count >= configuration.minimumIndependentEvents else { continue }
            for start in events.indices {
                let anchor = events[start]
                let window = events[start...].prefix(while: { eventTime($0) <= eventTime(anchor).addingTimeInterval(configuration.windowSeconds) })
                let independent = Array(Dictionary(window.map { ($0.id, $0) }, uniquingKeysWith: { old, _ in old }).values)
                    .sorted { eventTime($0) < eventTime($1) }
                guard independent.count >= configuration.minimumIndependentEvents else { continue }
                let selected = Array(independent.prefix(configuration.minimumIndependentEvents))
                let sources = Set(selected.flatMap(\.corroboratingSources))
                let hasMajor = selected.contains { $0.priority >= configuration.minimumPriority }
                guard sources.count >= configuration.minimumSources, hasMajor else { continue }
                let key = "\(sector)|\(anchor.id)"
                guard state.firedSectorClusterKeys.insert(key).inserted else { continue }
                let highestPriority = selected.map(\.priority).max() ?? 1
                result.append(AlertSignal(code: "SECTOR:\(sector)", ruleID: RuleFamily.sectorEventCluster.rawValue,
                    level: highestPriority >= 4 ? .urgent : .warning,
                    title: "板块事件聚集：\(sector)",
                    detail: "\(selected.count) 个独立事件 · \(sources.count) 个来源 · 60 分钟内至少一条 P1–P3",
                    createdAt: now))
                break
            }
        }
        return result
    }

    private mutating func makeCompleteBars(_ quotes: [Quote], now: Date) -> [MinuteBar] {
        var completed: [MinuteBar] = []
        for quote in quotes.sorted(by: { $0.timestamp < $1.timestamp }) {
            var buckets = state.quoteMinuteBucketsByCode[quote.code, default: []]
            let currentStart = Self.minuteStart(quote.timestamp)
            if let lastIndex = buckets.indices.last, buckets[lastIndex].minuteStart == currentStart {
                buckets[lastIndex].append(quote)
            } else if !buckets.contains(where: { $0.minuteStart == currentStart }) {
                buckets.append(MinuteQuoteBucket(quote: quote))
                buckets.sort { $0.minuteStart < $1.minuteStart }
            } else if let index = buckets.firstIndex(where: { $0.minuteStart == currentStart }) {
                buckets[index].append(quote)
            }
            buckets = Array(buckets.suffix(3))
            state.quoteMinuteBucketsByCode[quote.code] = buckets
            guard buckets.count == 3 else { continue }
            let before = buckets[0]
            let target = buckets[1]
            let after = buckets[2]
            let targetEnd = target.minuteStart.addingTimeInterval(60)
            guard target.minuteStart.timeIntervalSince(before.minuteStart) == 60,
                  after.minuteStart.timeIntervalSince(target.minuteStart) == 60,
                  target.first.timestamp.timeIntervalSince(target.minuteStart) <= 5,
                  targetEnd.timeIntervalSince(target.last.timestamp) <= 5,
                  target.minuteStart.timeIntervalSince(before.last.timestamp) >= 0,
                  target.minuteStart.timeIntervalSince(before.last.timestamp) <= 5,
                  after.first.timestamp.timeIntervalSince(targetEnd) >= 0,
                  after.first.timestamp.timeIntervalSince(targetEnd) <= 5,
                  before.last.sourceID == target.first.sourceID,
                  target.first.sourceID == target.last.sourceID,
                  target.last.sourceID == after.first.sourceID,
                  after.first.volume >= before.last.volume,
                  state.lastFiredAt["bar-builder:\(quote.code):\(target.minuteStart.timeIntervalSince1970)"] == nil else { continue }
            let amount: Double?
            if let startAmount = before.last.amount, let endAmount = after.first.amount,
               endAmount >= startAmount { amount = endAmount - startAmount }
            else { amount = nil }
            let bar = MinuteBar(code: quote.code, name: target.first.name,
                timestamp: target.minuteStart, open: target.first.price, close: target.last.price,
                high: target.high, low: target.low, volume: after.first.volume - before.last.volume,
                amount: amount, previousClose: target.first.previousClose,
                sourceID: "quote-delta:\(target.first.sourceID)", fetchedAt: now)
            state.lastFiredAt["bar-builder:\(quote.code):\(target.minuteStart.timeIntervalSince1970)"] = now
            completed.append(bar)
        }
        return completed
    }

    private mutating func recordQuoteHistory(_ quotes: [Quote], now: Date) {
        for quote in quotes where quote.timestampIsProvider && quote.price.isFinite && quote.timestamp >= now.addingTimeInterval(-45 * 60) {
            let key = Self.quoteHistoryKey(quote)
            let minute = Self.minuteStart(quote.timestamp)
            var history = state.quoteHistoryByKey[key, default: []]
            if let index = history.firstIndex(where: { Self.minuteStart($0.timestamp) == minute }) {
                if quote.timestamp >= history[index].timestamp { history[index] = quote }
            } else { history.append(quote) }
            history.sort { $0.timestamp < $1.timestamp }
            state.quoteHistoryByKey[key] = history.filter { $0.timestamp >= now.addingTimeInterval(-45 * 60) }
        }
    }

    @discardableResult
    private mutating func remember(_ bar: MinuteBar, updateVWAP: Bool) -> Bool {
        var bars = state.recentBarsByCode[bar.code, default: []]
        guard !bars.contains(where: { $0.id == bar.id }) else { return false }
        let day = Self.dayKey(bar.timestamp)
        if state.sessionDayByCode[bar.code] != day {
            state.sessionDayByCode[bar.code] = day
            state.observedHighByCode.removeValue(forKey: bar.code)
            state.observedLowByCode.removeValue(forKey: bar.code)
            state.vwapVolumeByCode[bar.code] = 0
            state.vwapAmountByCode[bar.code] = 0
            state.smaSignByCode.removeValue(forKey: bar.code)
            state.smaCandidateDirectionByCode.removeValue(forKey: bar.code)
            state.smaCandidateCountByCode.removeValue(forKey: bar.code)
            bars.removeAll { !Self.sameChinaDay($0.timestamp, bar.timestamp) }
        }
        bars.append(bar)
        bars.sort { $0.timestamp < $1.timestamp }
        state.recentBarsByCode[bar.code] = Array(bars.suffix(60))
        if updateVWAP, let amount = bar.amount, amount >= 0, bar.volume > 0 {
            state.vwapVolumeByCode[bar.code, default: 0] += Double(bar.volume)
            state.vwapAmountByCode[bar.code, default: 0] += amount
        }
        return true
    }

    private mutating func resetDailyStateIfNeeded(code: String, at date: Date) {
        let day = Self.dayKey(date)
        guard state.sessionDayByCode[code] != day else { return }
        state.sessionDayByCode[code] = day
        state.observedHighByCode.removeValue(forKey: code)
        state.observedLowByCode.removeValue(forKey: code)
        state.vwapVolumeByCode[code] = 0
        state.vwapAmountByCode[code] = 0
        state.recentBarsByCode[code] = []
        state.smaSignByCode.removeValue(forKey: code)
        state.smaCandidateDirectionByCode.removeValue(forKey: code)
        state.smaCandidateCountByCode.removeValue(forKey: code)
    }

    private mutating func confirmed(_ family: RuleFamily, code: String, direction: String,
                                   matches: Bool, required: Int) -> Bool {
        let key = confirmationKey(family, code: code, direction: direction)
        if matches { state.confirmationCounts[key, default: 0] += 1 }
        else { state.confirmationCounts[key] = 0 }
        return matches && state.confirmationCounts[key, default: 0] >= max(1, required)
    }

    private mutating func fire(_ family: RuleFamily, code: String, direction: String, daily: Bool,
                               settings: RuleFamilySettings, level: AlertLevel, title: String,
                               detail: String, at date: Date) -> AlertSignal? {
        guard settings.enabled, allowed(settings, at: date) else { return nil }
        let dayKey = Self.dayKey(date)
        let dailyKey = "\(family.rawValue)|\(code)|\(dayKey)|\(direction)"
        if daily && state.firedDailyKeys.contains(dailyKey) { return nil }
        let cooldownDirection = (family == .dailyChange || family == .minutePriceSpeed) ? direction : "any"
        let cooldownKey = "\(family.rawValue)|\(code)|\(cooldownDirection)"
        if let last = state.lastFiredAt[cooldownKey], date.timeIntervalSince(last) < settings.cooldownSeconds { return nil }
        state.lastFiredAt[cooldownKey] = date
        if daily { state.firedDailyKeys.insert(dailyKey) }
        return AlertSignal(code: code, ruleID: family.rawValue, level: level,
            title: title, detail: detail, createdAt: date)
    }

    private func setting(_ family: RuleFamily) -> RuleFamilySettings {
        settingsByFamily[family] ?? RuleFamilySettings.defaultsByFamily()[family]!
    }

    private func allowed(_ settings: RuleFamilySettings, at date: Date) -> Bool {
        guard settings.enabled else { return false }
        if settings.sessionOnly && !MarketClock.isTradingSession(date) { return false }
        guard let start = settings.quietStartMinute, let end = settings.quietEndMinute, start != end else { return true }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketClock.timeZone
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        let isQuiet = start < end ? minute >= start && minute < end : minute >= start || minute < end
        return !isQuiet
    }

    private func confirmationKey(_ family: RuleFamily, code: String, direction: String) -> String {
        "\(family.rawValue)|\(code)|\(direction)"
    }

    private func eventTime(_ event: MarketEvent) -> Date { event.latestPublishedAt ?? event.publishedAt ?? event.fetchedAt }

    private mutating func pruneState(now: Date) {
        let cutoff = now.addingTimeInterval(-45 * 60)
        for key in state.quoteHistoryByKey.keys {
            state.quoteHistoryByKey[key] = state.quoteHistoryByKey[key, default: []].filter { $0.timestamp >= cutoff }
        }
        let eventCutoff = now.addingTimeInterval(-3 * 60 * 60)
        let recentSectorEvents = state.recentSectorEvents
        state.recentSectorEvents = recentSectorEvents.filter { event in
            (event.latestPublishedAt ?? event.publishedAt ?? event.fetchedAt) >= eventCutoff
        }
        let validDay = Self.dayKey(now)
        state.firedDailyKeys = Set(state.firedDailyKeys.filter { $0.contains("|\(validDay)|") })
        let oldFireCutoff = now.addingTimeInterval(-48 * 60 * 60)
        state.lastFiredAt = state.lastFiredAt.filter { $0.value >= oldFireCutoff }
        state.lastEvaluatedQuoteTimestampByKey = state.lastEvaluatedQuoteTimestampByKey.filter { $0.value >= oldFireCutoff }
        state.confirmationCounts = state.confirmationCounts.filter { $0.value > 0 }
        if state.processedEventIDs.count > 5_000 { state.processedEventIDs = Set(state.processedEventIDs.sorted().suffix(3_000)) }
        if state.firedSectorClusterKeys.count > 5_000 { state.firedSectorClusterKeys = Set(state.firedSectorClusterKeys.sorted().suffix(3_000)) }
    }

    private static func quoteHistoryKey(_ quote: Quote) -> String { "\(quote.kind.rawValue):\(quote.code)" }

    private static func minuteStart(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970 / 60) * 60)
    }

    private static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = MarketClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func sameChinaDay(_ lhs: Date, _ rhs: Date) -> Bool { dayKey(lhs) == dayKey(rhs) }

    private static func areContiguous(_ bars: [MinuteBar]) -> Bool {
        guard bars.count > 1 else { return false }
        for index in 1..<bars.count where bars[index].timestamp.timeIntervalSince(bars[index - 1].timestamp) != 60 { return false }
        return true
    }
}

public extension MinuteBar {
    /// Eastmoney returns the live minute as well as completed rows. A row is complete
    /// only after its 60-second interval ended before the source response was fetched.
    var isComplete: Bool { timestamp.addingTimeInterval(60) <= fetchedAt }
}

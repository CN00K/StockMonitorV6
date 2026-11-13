import Foundation

public enum EnginePhase: String, Sendable {
    case closed, coldStart, reconciling, live, paused, failed
}

public struct EngineViewState: Sendable {
    public let phase: EnginePhase
    public let isReconciling: Bool
    public let watchCodes: [String]
    public let watchRules: [WatchRule]
    public let ruleFamilySettings: [RuleFamilySettings]
    public let holdings: [Holding]
    public let latestSnapshot: MarketSnapshot?
    public let unreadSignals: [AlertSignal]
    public let sourceStatuses: [SourceStatus]
    public let reconcileReport: ReconcileReport?
    public let limitPriceStatus: String
    public let lastError: String?
    public let isMarketSession: Bool

    public init(phase: EnginePhase, isReconciling: Bool = false,
                watchCodes: [String], watchRules: [WatchRule] = [],
                ruleFamilySettings: [RuleFamilySettings] = RuleFamilySettings.defaults,
                holdings: [Holding] = [], latestSnapshot: MarketSnapshot?,
                unreadSignals: [AlertSignal], sourceStatuses: [SourceStatus] = [],
                reconcileReport: ReconcileReport? = nil,
                limitPriceStatus: String = "Daily limit-price data is unknown",
                lastError: String?, isMarketSession: Bool) {
        self.phase = phase
        self.isReconciling = isReconciling
        self.watchCodes = watchCodes
        self.watchRules = watchRules
        self.ruleFamilySettings = ruleFamilySettings
        self.holdings = holdings
        self.latestSnapshot = latestSnapshot
        self.unreadSignals = unreadSignals
        self.sourceStatuses = sourceStatuses
        self.reconcileReport = reconcileReport
        self.limitPriceStatus = limitPriceStatus
        self.lastError = lastError
        self.isMarketSession = isMarketSession
    }
}

/// All monitoring work is driven by a foreground session. The host must call
/// `stop()` as soon as the scene enters the background.
public actor LiveEngine {
    public static let unknownLimitPriceNote = "每日涨跌停价未知：当前未配置可验证的逐股限价源；涨跌停规则不会触发。"

    private let store: any MonitorStore
    private let source: any MarketDataProviding
    private let historicalSource: (any HistoricalReconcileSource)?
    private let requestBudget: RequestBudget?
    private var rules: RuleEngine
    private var familyRules = RuleFamilyEngine()
    private var phase: EnginePhase = .closed
    private var isReconciling = false
    private var watchCodes: [String] = []
    private var watchRules: [WatchRule] = []
    private var holdings: [Holding] = []
    private var latestSnapshot: MarketSnapshot?
    private var unreadSignals: [AlertSignal] = []
    private var quoteSourceStatuses: [SourceStatus] = []
    private var historySourceStatus: SourceStatus?
    private var reconcileReport: ReconcileReport?
    private var tickTask: Task<Void, Never>?
    private var activePollTask: Task<MarketDataBatch, Never>?
    private var activeReconcileTask: Task<ReconcileResult, Never>?
    private var activePollRequestID: UUID?
    private var activeReconcileRequestID: UUID?
    private var lastError: String?
    private var lastQuoteTimeByCode: [String: Date] = [:]
    private var lifecycleGeneration = 0
    private var sessionOpen = false
    private var databaseOpen = false

    public init(store: any MonitorStore, source: any MarketDataProviding,
                historicalSource: (any HistoricalReconcileSource)? = nil,
                requestBudget: RequestBudget? = nil, rules: RuleEngine = RuleEngine()) {
        self.store = store
        self.source = source
        self.historicalSource = historicalSource
        self.requestBudget = requestBudget
        self.rules = rules
    }

    public func start(now: Date = Date()) async {
        guard !Task.isCancelled, phase != .live else { return }
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        phase = .coldStart
        lastError = nil
        do {
            await requestBudget?.beginSession()
            try await store.open()
            databaseOpen = true
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            let restored = try await store.restoreState()
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            watchCodes = restored.watchCodes
            watchRules = restored.watchRules
            holdings = restored.holdings
            unreadSignals = restored.unreadSignals
            lastQuoteTimeByCode = restored.lastQuoteTimeByCode
            historySourceStatus = nil
            reconcileReport = nil
            isReconciling = false
            rules.replaceRules(restored.watchRules)
            familyRules.replaceSettings(restored.ruleFamilySettings.isEmpty ? RuleFamilySettings.defaults : restored.ruleFamilySettings)
            familyRules.restoreCheckpoint(restored.ruleCheckpoint)
            if restored.ruleFamilySettings.isEmpty { try await store.setRuleFamilySettings(familyRules.settings) }
            let seedCodes = Array(Set(watchCodes + MarketIndex.core.map(\.code))).sorted()
            let savedQuotes = try await store.fetchRecentQuotes(codes: seedCodes, since: now.addingTimeInterval(-45 * 60))
            familyRules.seedQuoteHistory(savedQuotes, now: now)
            let savedBars = try await store.fetchRecentMinuteBars(codes: watchCodes, since: Self.chinaDayStart(now))
            familyRules.seedMinuteBars(savedBars)
            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            let restoredCapture = (restored.latestQuotes + restored.latestIndexQuotes).map(\.retrievedAt).max()
            if restored.latestQuotes.isEmpty && restored.latestIndexQuotes.isEmpty {
                latestSnapshot = nil
            } else {
                latestSnapshot = MarketSnapshot(capturedAt: restoredCapture ?? now,
                    quotes: restored.latestQuotes, indexQuotes: restored.latestIndexQuotes,
                    sourceStatuses: [], limitPriceStatus: Self.unknownLimitPriceNote)
            }

            guard generation == lifecycleGeneration, !Task.isCancelled else { return }
            try await store.beginSession(at: now)
            sessionOpen = true
            guard generation == lifecycleGeneration, !Task.isCancelled else {
                try? await store.endSession(at: Date())
                sessionOpen = false
                try? await store.checkpoint()
                return
            }
            phase = .live
            startTicking()
            if let historicalSource {
                var cursors = restored.lastQuoteTimeByCode
                for (code, time) in restored.lastMinuteTimestampByCode {
                    if time > (cursors[code] ?? .distantPast) { cursors[code] = time }
                }
                beginReconciliation(source: historicalSource, codes: watchCodes,
                    afterByCode: cursors, generation: generation, evaluationDate: now)
            }
            Task { [weak self] in await self?.pollNow(now: now) }
        } catch {
            if generation == lifecycleGeneration {
                phase = .failed
                lastError = error.localizedDescription
            }
        }
    }

    /// Cancellation happens before any database await, so a stale poll cannot start after backgrounding.
    public func stop(at date: Date = Date()) async {
        lifecycleGeneration += 1
        tickTask?.cancel()
        tickTask = nil
        activePollTask?.cancel()
        activePollTask = nil
        activePollRequestID = nil
        activeReconcileTask?.cancel()
        activeReconcileTask = nil
        activeReconcileRequestID = nil
        isReconciling = false
        phase = .paused
        if databaseOpen {
            do { try await store.setRuleCheckpoint(familyRules.checkpoint) }
            catch { lastError = error.localizedDescription }
        }
        if sessionOpen {
            do { try await store.endSession(at: date); sessionOpen = false }
            catch { lastError = error.localizedDescription }
        }
        if databaseOpen {
            do { try await store.checkpoint() }
            catch { lastError = error.localizedDescription }
        }
    }

    public func setWatchCodes(_ codes: [String]) async {
        let normalized = Array(Set(codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.range(of: "^[0-9]{6}$", options: .regularExpression) != nil })).sorted()
        watchCodes = normalized
        do { try await store.setWatchCodes(normalized) }
        catch { lastError = error.localizedDescription }
        if phase == .live { await pollNow() }
    }

    public func replaceRules(_ newRules: [WatchRule]) async {
        watchRules = newRules
        rules.replaceRules(newRules)
        do { try await store.setRules(newRules) }
        catch { lastError = error.localizedDescription }
    }

    public func replaceRuleFamilySettings(_ newSettings: [RuleFamilySettings]) async {
        familyRules.replaceSettings(newSettings)
        do { try await store.setRuleFamilySettings(familyRules.settings) }
        catch { lastError = error.localizedDescription }
    }

    public func evaluateEvents(_ events: [MarketEvent], now: Date = Date()) async {
        guard databaseOpen, !events.isEmpty else { return }
        let previousCheckpoint = familyRules.checkpoint
        let signals = familyRules.evaluateEvents(events, watchCodes: watchCodes, now: now)
        do {
            try await store.commitLiveEvaluation(quotes: [], indexQuotes: [], bars: [],
                signals: signals, ruleCheckpoint: familyRules.checkpoint)
            if !signals.isEmpty { unreadSignals = Array((signals + unreadSignals).prefix(200)) }
        } catch {
            familyRules.restoreCheckpoint(previousCheckpoint)
            lastError = error.localizedDescription
        }
    }

    public func replaceHoldings(_ newHoldings: [Holding]) async {
        holdings = newHoldings
        do { try await store.setHoldings(newHoldings) }
        catch { lastError = error.localizedDescription }
    }

    /// Daily history access is invoked only by the explicit backtest flow.
    public func saveDailyBars(_ bars: [DailyBar]) async throws {
        if !databaseOpen { try await store.open(); databaseOpen = true }
        try await store.upsertDailyBars(bars)
    }

    public func dailyBars(codes: [String], from: Date, to: Date) async throws -> [DailyBar] {
        if !databaseOpen { try await store.open(); databaseOpen = true }
        return try await store.fetchDailyBars(codes: codes, from: from, to: to)
    }

    public func markSignalRead(_ id: UUID, at date: Date = Date()) async {
        do {
            try await store.markSignalRead(id, at: date)
            unreadSignals.removeAll { $0.id == id }
        } catch { lastError = error.localizedDescription }
    }

    public func state(now: Date = Date()) -> EngineViewState {
        EngineViewState(phase: phase, isReconciling: isReconciling,
            watchCodes: watchCodes, watchRules: watchRules, ruleFamilySettings: familyRules.settings,
            holdings: holdings, latestSnapshot: latestSnapshot, unreadSignals: unreadSignals,
            sourceStatuses: allSourceStatuses, reconcileReport: reconcileReport,
            limitPriceStatus: Self.unknownLimitPriceNote, lastError: lastError,
            isMarketSession: MarketClock.isTradingSession(now))
    }

    public func pollNow(now: Date = Date()) async {
        guard phase == .live, MarketClock.isTradingSession(now), activePollRequestID == nil else { return }
        let generation = lifecycleGeneration
        do {
            let source = self.source
            let requestID = UUID()
            let fetchTask = Task { await source.fetch(codes: watchCodes, indices: MarketIndex.core) }
            activePollRequestID = requestID
            activePollTask = fetchTask
            let batch = await fetchTask.value
            if activePollRequestID == requestID {
                activePollTask = nil
                activePollRequestID = nil
            }
            guard phase == .live, generation == lifecycleGeneration, !Task.isCancelled else { return }
            quoteSourceStatuses = batch.sourceStatuses
            let statuses = allSourceStatuses
            guard !batch.quotes.isEmpty || !batch.indexQuotes.isEmpty else {
                if !batch.missingCodes.isEmpty || !batch.missingIndexCodes.isEmpty {
                    lastError = "No usable quote returned; missing \((batch.missingCodes + batch.missingIndexCodes).joined(separator: ", "))."
                }
                if let oldSnapshot = latestSnapshot {
                    latestSnapshot = MarketSnapshot(capturedAt: oldSnapshot.capturedAt,
                        quotes: oldSnapshot.quotes, indexQuotes: oldSnapshot.indexQuotes,
                        sourceStatuses: statuses, limitPriceStatus: Self.unknownLimitPriceNote)
                }
                return
            }
            var stocksByCode = Dictionary((latestSnapshot?.quotes ?? []).map { ($0.code, $0) }, uniquingKeysWith: { _, new in new })
            for quote in batch.quotes { stocksByCode[quote.code] = quote }
            var indicesByCode = Dictionary((latestSnapshot?.indexQuotes ?? []).map { ($0.code, $0) }, uniquingKeysWith: { _, new in new })
            for quote in batch.indexQuotes { indicesByCode[quote.code] = quote }
            let currentStocks = watchCodes.compactMap { stocksByCode[$0] }
            let currentIndices = MarketIndex.core.compactMap { indicesByCode[$0.code] }
            let previous = latestSnapshot
            latestSnapshot = MarketSnapshot(capturedAt: now, quotes: currentStocks,
                indexQuotes: currentIndices, limits: [:], sourceStatuses: statuses,
                limitPriceStatus: Self.unknownLimitPriceNote)
            for quote in batch.quotes {
                let old = lastQuoteTimeByCode[quote.code] ?? .distantPast
                if quote.timestamp > old { lastQuoteTimeByCode[quote.code] = quote.timestamp }
            }
            lastError = nil
            let strategyQuotes = batch.quotes.filter {
                $0.timestampIsProvider && abs(now.timeIntervalSince($0.timestamp)) <= 120
            }
            let strategyIndices = batch.indexQuotes.filter {
                $0.timestampIsProvider && abs(now.timeIntervalSince($0.timestamp)) <= 120
            }
            let evaluation = MarketSnapshot(capturedAt: now, quotes: strategyQuotes, indexQuotes: strategyIndices, limits: [:],
                sourceStatuses: statuses, limitPriceStatus: Self.unknownLimitPriceNote)
            let previousFamilyCheckpoint = familyRules.checkpoint
            let previousLegacyRules = rules
            let legacySignals = rules.evaluate(current: evaluation, previous: previous, now: now)
            let familyEvaluation = familyRules.evaluateDetailed(current: evaluation, holdings: holdings, now: now)
            let newSignals = legacySignals + familyEvaluation.signals
            do {
                try await store.commitLiveEvaluation(quotes: batch.quotes, indexQuotes: batch.indexQuotes,
                    bars: familyEvaluation.completedBars, signals: newSignals,
                    ruleCheckpoint: familyRules.checkpoint)
            } catch {
                familyRules.restoreCheckpoint(previousFamilyCheckpoint)
                rules = previousLegacyRules
                throw error
            }
            guard phase == .live, generation == lifecycleGeneration, !Task.isCancelled else { return }
            if !newSignals.isEmpty {
                unreadSignals = Array((newSignals + unreadSignals).sorted { $0.createdAt > $1.createdAt }.prefix(200))
            }
            if !batch.missingCodes.isEmpty || !batch.missingIndexCodes.isEmpty {
                lastError = "Partial quotes; missing \((batch.missingCodes + batch.missingIndexCodes).joined(separator: ", "))."
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private var allSourceStatuses: [SourceStatus] {
        quoteSourceStatuses + (historySourceStatus.map { [$0] } ?? [])
    }

    private func beginReconciliation(source: any HistoricalReconcileSource,
                                     codes: [String], afterByCode: [String: Date],
                                     generation: Int, evaluationDate: Date) {
        let requestID = UUID()
        activeReconcileRequestID = requestID
        isReconciling = true
        activeReconcileTask = Task { [weak self] in
            let result = await source.reconcile(codes: codes, afterByCode: afterByCode)
            guard !Task.isCancelled else { return result }
            await self?.finishReconciliation(result, requestID: requestID,
                generation: generation, evaluationDate: evaluationDate)
            return result
        }
    }

    private func finishReconciliation(_ result: ReconcileResult,
                                      requestID: UUID, generation: Int, evaluationDate: Date) async {
        guard generation == lifecycleGeneration, phase == .live,
              activeReconcileRequestID == requestID, !Task.isCancelled else { return }
        historySourceStatus = result.status
        reconcileReport = result.report
        let previousCheckpoint = familyRules.checkpoint
        let recoveredSignals = evaluateHistoricalBars(result.bars, now: evaluationDate)
        do {
            try await store.commitReconciliation(bars: result.bars, signals: recoveredSignals,
                ruleCheckpoint: familyRules.checkpoint)
            guard generation == lifecycleGeneration, phase == .live,
                  activeReconcileRequestID == requestID, !Task.isCancelled else { return }
            if !recoveredSignals.isEmpty {
                unreadSignals = Array((recoveredSignals + unreadSignals)
                    .sorted { $0.createdAt > $1.createdAt }.prefix(200))
            }
        } catch {
            familyRules.restoreCheckpoint(previousCheckpoint)
            if generation == lifecycleGeneration { lastError = error.localizedDescription }
        }
        if activeReconcileRequestID == requestID {
            isReconciling = false
            activeReconcileTask = nil
            activeReconcileRequestID = nil
        }
    }

    private func evaluateHistoricalBars(_ bars: [MinuteBar], now: Date) -> [AlertSignal] {
        guard !bars.isEmpty else { return [] }
        var result = familyRules.evaluateMinuteBars(bars, now: now)
        var evaluator = rules.historicalEvaluator()
        let grouped = Dictionary(grouping: bars, by: \.timestamp)
        for timestamp in grouped.keys.sorted() {
            let group = (grouped[timestamp] ?? []).sorted { $0.code < $1.code }
            var quotes: [Quote] = []
            var knownPreviousClose = Set<String>()
            for bar in group {
                if let previousClose = bar.previousClose, previousClose > 0 { knownPreviousClose.insert(bar.code) }
                let previousClose = bar.previousClose ?? bar.close
                quotes.append(Quote(code: bar.code, name: bar.name, timestamp: bar.timestamp,
                    price: bar.close, previousClose: previousClose, open: bar.open,
                    high: bar.high, low: bar.low, volume: bar.volume, amount: bar.amount,
                    sourceID: bar.sourceID, retrievedAt: bar.fetchedAt, timestampIsProvider: true))
            }
            let snapshot = MarketSnapshot(capturedAt: timestamp, quotes: quotes,
                limitPriceStatus: Self.unknownLimitPriceNote)
            result.append(contentsOf: evaluator.evaluateHistorical(current: snapshot,
                previousCloseKnownCodes: knownPreviousClose, now: timestamp))
        }
        return result
    }

    private func startTicking() {
        tickTask?.cancel()
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let count = await self.watchCount()
#if os(iOS) || os(macOS)
                let processInfo = ProcessInfo.processInfo
                let lowPowerMode = processInfo.isLowPowerModeEnabled
                let thermalIsElevated = processInfo.thermalState == .serious
                    || processInfo.thermalState == .critical
#else
                let lowPowerMode = false
                let thermalIsElevated = false
#endif
                let delay = MarketClock.suggestedInterval(
                    watchCount: count,
                    lowPowerMode: lowPowerMode,
                    thermalIsElevated: thermalIsElevated)
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self.pollNow()
            }
        }
    }

    private func watchCount() -> Int { watchCodes.count }

    private static func chinaDayStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketClock.timeZone
        return calendar.startOfDay(for: date)
    }
}

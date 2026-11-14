import Foundation

public struct RuntimeFeatureAvailability: Sendable, Equatable {
    public let enabled: Bool
    public let reason: String?

    public init(enabled: Bool, reason: String? = nil) {
        self.enabled = enabled
        self.reason = enabled ? nil : reason
    }
}

public struct StockMonitorRuntimeCapabilities: Sendable, Equatable {
    public let marketScan: RuntimeFeatureAvailability
    public let moneyFlow: RuntimeFeatureAvailability
    public let automaticEventLLM: RuntimeFeatureAvailability
    public let fundamentals: RuntimeFeatureAvailability
    public let encryptedBackup: RuntimeFeatureAvailability
    public let markdownAndPDFReports: RuntimeFeatureAvailability
    public let alertDelivery: RuntimeFeatureAvailability
}

/// Configuration for the functional composition layer. Optional data decorators
/// are bounded and share the foreground RequestBudget. LLM enrichment is requested
/// by default to honor the approved tier policy, but remains inactive unless the
/// endpoint, model, client, and Keychain-backed key provider are all present.
public struct StockMonitorRuntimeConfiguration: Sendable {
    public let databaseURL: URL?
    public let appGroupIdentifier: String?
    public let marketScanEnabled: Bool
    public let marketScanRefreshInterval: TimeInterval
    public let marketScanMaximumPages: Int
    public let marketScanMaximumSecurities: Int
    public let fullMarketScanEnabled: Bool
    public let fullMarketScanRefreshInterval: TimeInterval
    public let fullMarketScanMaximumPages: Int
    public let fullMarketScanMaximumSecurities: Int
    public let moneyFlowEnabled: Bool
    public let moneyFlowMaximumSymbolsPerRefresh: Int
    public let moneyFlowRefreshInterval: TimeInterval
    public let moneyFlowMaximumAge: TimeInterval
    public let automaticTieredEventEnrichmentRequested: Bool
    public let eventLLMEndpoint: URL?
    public let eventLLMModelID: String?
    public let eventLLMKeyProvider: (any EventLLMAPIKeyProvider)?
    public let eventPolicy: CollectorEventPolicy
    public let maximumEventsPerSource: Int
    public let maximumFundamentalCodes: Int

    public init(databaseURL: URL? = nil,
                appGroupIdentifier: String? = "group.com.cn00k.stockmonitorv6",
                marketScanEnabled: Bool = true,
                marketScanRefreshInterval: TimeInterval = 15 * 60,
                marketScanMaximumPages: Int = 10,
                marketScanMaximumSecurities: Int = 1_000,
                fullMarketScanEnabled: Bool = true,
                fullMarketScanRefreshInterval: TimeInterval = 15 * 60,
                fullMarketScanMaximumPages: Int = 60,
                fullMarketScanMaximumSecurities: Int = 6_000,
                moneyFlowEnabled: Bool = true,
                moneyFlowMaximumSymbolsPerRefresh: Int = 2,
                moneyFlowRefreshInterval: TimeInterval = 10 * 60,
                moneyFlowMaximumAge: TimeInterval = 2 * 60,
                automaticTieredEventEnrichmentRequested: Bool = true,
                eventLLMEndpoint: URL? = nil,
                eventLLMModelID: String? = nil,
                eventLLMKeyProvider: (any EventLLMAPIKeyProvider)? = nil,
                eventPolicy: CollectorEventPolicy = .stockAgentDefaults,
                maximumEventsPerSource: Int = 30,
                maximumFundamentalCodes: Int = 10) {
        self.databaseURL = databaseURL
        self.appGroupIdentifier = appGroupIdentifier
        self.marketScanEnabled = marketScanEnabled
        self.marketScanRefreshInterval = max(60, marketScanRefreshInterval)
        self.marketScanMaximumPages = min(100, max(1, marketScanMaximumPages))
        self.marketScanMaximumSecurities = min(6_000, max(1, marketScanMaximumSecurities))
        self.fullMarketScanEnabled = fullMarketScanEnabled
        self.fullMarketScanRefreshInterval = max(60, fullMarketScanRefreshInterval)
        self.fullMarketScanMaximumPages = min(100, max(1, fullMarketScanMaximumPages))
        self.fullMarketScanMaximumSecurities = min(6_000, max(1, fullMarketScanMaximumSecurities))
        self.moneyFlowEnabled = moneyFlowEnabled
        self.moneyFlowMaximumSymbolsPerRefresh = min(50, max(1, moneyFlowMaximumSymbolsPerRefresh))
        self.moneyFlowRefreshInterval = max(1, moneyFlowRefreshInterval)
        self.moneyFlowMaximumAge = min(120, max(30, moneyFlowMaximumAge))
        self.automaticTieredEventEnrichmentRequested = automaticTieredEventEnrichmentRequested
        self.eventLLMEndpoint = eventLLMEndpoint
        self.eventLLMModelID = eventLLMModelID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.eventLLMKeyProvider = eventLLMKeyProvider
        self.eventPolicy = eventPolicy
        self.maximumEventsPerSource = min(100, max(1, maximumEventsPerSource))
        self.maximumFundamentalCodes = min(50, max(1, maximumFundamentalCodes))
    }
}

/// Adapter from the app's Keychain-backed CredentialStore. The key is loaded per
/// event-refresh and is neither cached in this object nor written to SQLite/logs.
public struct CredentialStoreEventLLMAPIKeyProvider: EventLLMAPIKeyProvider {
    private let store: any CredentialStore
    private let identifier: CredentialIdentifier

    public init(store: any CredentialStore, identifier: CredentialIdentifier = .llmProviderAPIKey()) {
        self.store = store
        self.identifier = identifier
    }

    public func apiKey() async -> String? {
        guard let data = try? store.read(identifier),
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }
}

public struct StockMonitorRuntimeDependencies: Sendable {
    public let store: SQLiteMonitorStore
    public let requestBudget: RequestBudget
    public let quoteProvider: any MarketDataProviding
    public let minuteHistorySource: (any HistoricalReconcileSource)?
    public let dailyHistorySource: (any DailyHistoryProviding)?
    public let fundamentalsSource: (any MarketFundamentalsProviding)?
    public let moneyFlowSource: (any MoneyFlowProviding)?
    public let marketCoverageSource: (any MarketCoverageProviding)?
    public let fullMarketCoverageSource: (any MarketCoverageProviding)?
    public let eventSources: [any MarketEventSource]
    public let eventLLMClient: (any EventLLMEnrichmentClient)?
    public let sectorTagger: SectorTagger?
    public let limitSource: (any DailyLimitSource)?
    public let backupCipher: any BackupCipher
    public let alertDelivery: (any AlertDelivery)?

    public init(store: SQLiteMonitorStore, requestBudget: RequestBudget,
                quoteProvider: any MarketDataProviding,
                minuteHistorySource: (any HistoricalReconcileSource)? = nil,
                dailyHistorySource: (any DailyHistoryProviding)? = nil,
                fundamentalsSource: (any MarketFundamentalsProviding)? = nil,
                moneyFlowSource: (any MoneyFlowProviding)? = nil,
                marketCoverageSource: (any MarketCoverageProviding)? = nil,
                fullMarketCoverageSource: (any MarketCoverageProviding)? = nil,
                eventSources: [any MarketEventSource] = [],
                eventLLMClient: (any EventLLMEnrichmentClient)? = nil,
                sectorTagger: SectorTagger? = nil,
                limitSource: (any DailyLimitSource)? = nil,
                backupCipher: any BackupCipher = AuthenticatedBackupCipher(),
                alertDelivery: (any AlertDelivery)? = nil) {
        self.store = store
        self.requestBudget = requestBudget
        self.quoteProvider = quoteProvider
        self.minuteHistorySource = minuteHistorySource
        self.dailyHistorySource = dailyHistorySource
        self.fundamentalsSource = fundamentalsSource
        self.moneyFlowSource = moneyFlowSource
        self.marketCoverageSource = marketCoverageSource
        self.fullMarketCoverageSource = fullMarketCoverageSource
        self.eventSources = eventSources
        self.eventLLMClient = eventLLMClient
        self.sectorTagger = sectorTagger
        self.limitSource = limitSource
        self.backupCipher = backupCipher
        self.alertDelivery = alertDelivery
    }
}

public struct DailyHistoryRefreshOutcome: Sendable {
    public let batch: DailyHistoryBatch
    public let storageError: String?

    public init(batch: DailyHistoryBatch, storageError: String? = nil) {
        self.batch = batch
        self.storageError = storageError
    }
}

/// A single injectable, testable core service graph. Construction creates no
/// network requests; sources run only when foreground/session methods are called.
public actor StockMonitorFunctionalRuntime {
    public nonisolated let store: SQLiteMonitorStore
    public let requestBudget: RequestBudget
    public let quoteProvider: any MarketDataProviding
    public nonisolated let engine: LiveEngine
    public let eventCollector: EventCollector
    public let fundamentals: LocalFundamentalsService?
    public let cachedAnalyst: CachedOnDemandAnalyst
    public let backupService: SQLitePortableBackupService
    public let alertDelivery: (any AlertDelivery)?
    public let capabilities: StockMonitorRuntimeCapabilities

    private let dailyHistorySource: (any DailyHistoryProviding)?
    private let fullMarketCoverageProvider: (any MarketCoverageProviding)?
    private let eventProcessor: EventProcessor
    private var latestEventStatuses: [EventSourceStatus] = []

    fileprivate init(configuration: StockMonitorRuntimeConfiguration,
                    dependencies: StockMonitorRuntimeDependencies,
                    engine: LiveEngine, eventCollector: EventCollector,
                    eventProcessor: EventProcessor,
                    fullMarketCoverageProvider: (any MarketCoverageProviding)?,
                    fundamentals: LocalFundamentalsService?,
                    cachedAnalyst: CachedOnDemandAnalyst,
                    backupService: SQLitePortableBackupService,
                    capabilities: StockMonitorRuntimeCapabilities) {
        self.store = dependencies.store
        self.requestBudget = dependencies.requestBudget
        self.quoteProvider = dependencies.quoteProvider
        self.engine = engine
        self.eventCollector = eventCollector
        self.dailyHistorySource = dependencies.dailyHistorySource
        self.fullMarketCoverageProvider = fullMarketCoverageProvider
        self.eventProcessor = eventProcessor
        self.fundamentals = fundamentals
        self.cachedAnalyst = cachedAnalyst
        self.backupService = backupService
        self.alertDelivery = dependencies.alertDelivery
        self.capabilities = capabilities
    }

    public func startMonitoring(now: Date = Date()) async {
        await engine.start(now: now)
    }

    public func stopMonitoring(at date: Date = Date()) async {
        await engine.stop(at: date)
    }

    public func currentState(now: Date = Date()) async -> EngineViewState {
        await engine.state(now: now)
    }

    /// Explicit, bounded full-market scan. It may issue up to the configured page
    /// cap and is cached in this runtime process; quote ticks never invoke it.
    public func fetchFullMarketCoverage() async throws -> MarketCoverageSnapshot? {
        try await fullMarketCoverageProvider?.fetchCoverage()
    }

    /// Explicit refresh only; automatic sources have no timers or background work.
    /// New events are passed to live rule evaluation only during a foreground session.
    public func refreshEvents(since: Date, limitPerSource: Int? = nil) async -> EventCollectionReport {
        do { try await store.open() }
        catch {
            return EventCollectionReport(sourceStatuses: [], receivedCount: 0, storedCount: 0,
                storageError: "SQLite open failed: \(error.localizedDescription)")
        }
        let watchCodes = await engine.state().watchCodes
        let report = await eventCollector.refresh(since: since, stockCodes: watchCodes,
            limitPerSource: limitPerSource)
        latestEventStatuses = report.sourceStatuses
        if report.storageError == nil, !report.visibleEvents.isEmpty,
           await engine.state().phase == .live {
            await engine.evaluateEvents(report.visibleEvents)
        }
        return report
    }

    public func dailyEventSummary(on day: Date = Date(), generatedAt: Date = Date()) async throws -> DailyEventSummary {
        try await store.open()
        return try await eventCollector.dailySummary(on: day, generatedAt: generatedAt)
    }

    public func buildEventReport(morning: ReportWindow, midday: ReportWindow,
                                 generatedAt: Date = Date()) async throws -> ReportModel {
        try await store.open()
        return try await LocalEventReportService(store: store, processor: eventProcessor)
            .build(morning: morning, midday: midday, sourceStatuses: latestEventStatuses,
                   generatedAt: generatedAt)
    }

    public func exportReportPDF(_ report: ReportModel, to url: URL) throws {
        try LocalReportExporter.write(report: report, to: url, format: .pdf)
    }

    public func exportEvents(from start: Date, to end: Date,
                             format: EventExportFormat) async throws -> Data {
        try await store.open()
        guard start <= end else { return try EventExporter.encode(events: [], format: format) }
        let events = try await store.fetchEvents(from: start, to: end)
        return try EventExporter.encode(events: eventProcessor.process(events), format: format)
    }

    public func exportEventFile(from start: Date, to end: Date,
                                format: EventExportFormat) async throws -> URL {
        let data = try await exportEvents(from: start, to: end, format: format)
        let suffix = format.rawValue
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stock-monitor-events-\(UUID().uuidString).\(suffix)")
        try data.write(to: url, options: .atomic)
        return url
    }

    public func refreshFundamentals(codes: [String]) async -> FundamentalsRefreshReport? {
        await fundamentals?.refresh(codes: codes)
    }

    public func latestFundamentals(codes: [String]) async throws -> [EastmoneyFundamentalSnapshot] {
        guard let fundamentals else { return [] }
        return try await fundamentals.latest(codes: codes)
    }

    public func latestFundamentalObservations(codes: [String]) async throws -> [String: FactorObservation] {
        guard let fundamentals else { return [:] }
        return try await fundamentals.latestFactorObservations(codes: codes)
    }

    /// Explicit backtest/data-history action; it is never called by monitoring ticks.
    public func refreshDailyHistory(codes: [String], from: Date, to: Date) async -> DailyHistoryRefreshOutcome? {
        guard let dailyHistorySource else { return nil }
        let batch = await dailyHistorySource.fetchDailyHistory(codes: codes, from: from, to: to)
        do {
            try await store.open()
            try await store.upsertDailyBars(batch.bars)
            return DailyHistoryRefreshOutcome(batch: batch)
        } catch {
            let old = batch.status
            let status = SourceStatus(sourceID: old.sourceID, fetchedAt: old.fetchedAt,
                providerTimestamp: old.providerTimestamp, requestedCount: old.requestedCount,
                returnedCount: old.returnedCount, requestCount: old.requestCount,
                error: [old.error, error.localizedDescription].compactMap { $0 }.joined(separator: "; "),
                note: old.note)
            return DailyHistoryRefreshOutcome(batch: DailyHistoryBatch(bars: batch.bars,
                status: status, skippedCodes: batch.skippedCodes, warnings: batch.warnings),
                storageError: error.localizedDescription)
        }
    }

    public func dailyBars(codes: [String], from: Date, to: Date) async throws -> [DailyBar] {
        try await store.open()
        return try await store.fetchDailyBars(codes: codes, from: from, to: to)
    }

    /// The host must call this only after a user action; no analysis is started by
    /// runtime construction, quote polling, event refresh, or cache lookup alone.
    public func analyzeSelectedStock(context: AnalystContext,
                                     configuration: OnDemandAnalystConfiguration,
                                     apiKey: String, at date: Date = Date()) async throws -> StrategyResult {
        try await store.open()
        return try await cachedAnalyst.analyze(context: context, configuration: configuration,
                                               apiKey: apiKey, at: date)
    }

    public func latestSessionUsage() async throws -> MonitorSessionUsage? {
        try await store.open()
        return try await store.latestSessionUsage()
    }

    public func exportEncryptedBackup(using key: Data, at date: Date = Date()) async throws -> Data {
        try await backupService.export(using: key, at: date)
    }

    public func restoreEncryptedBackup(_ data: Data, using key: Data) async throws {
        try await backupService.restore(data, using: key)
    }

    /// Notification delivery is explicit and never requests permission by itself.
    public func deliverUnreadAlerts() async throws -> Bool {
        guard let alertDelivery else { return false }
        let state = await engine.state()
        guard let request = AlertDeliveryCore.request(for: state.unreadSignals) else { return false }
        try await alertDelivery.deliver(request)
        return true
    }

    public func applyAlertAction(_ command: AlertActionCommand) async -> Bool {
        switch command {
        case .markRead(let signalID):
            await engine.markSignalRead(signalID)
            return true
        case .snooze:
            // Snooze remains an app-boundary action; no misleading persisted mute is applied.
            return false
        }
    }

#if canImport(UserNotifications)
    /// Permission prompting is opt-in and must be initiated by the host at the
    /// product-appropriate point, not during runtime assembly.
    public func requestNotificationAuthorization() async throws -> Bool {
        guard let boundary = alertDelivery as? any AlertNotificationPermissionBoundary else { return false }
        return try await boundary.requestAuthorization()
    }
#endif
}

public enum StockMonitorFunctionalRuntimeFactory {
    public static func makeDefault(configuration: StockMonitorRuntimeConfiguration = .init()) -> StockMonitorFunctionalRuntime {
        let budget = RequestBudget.standard()
        let store = SQLiteMonitorStore(databaseURL: configuration.databaseURL,
                                       appGroupIdentifier: configuration.appGroupIdentifier)
        let quoteProvider = QuoteSourceRegistry(sources: [
            SinaQuoteSource(budget: budget),
            EastmoneyQuoteSource(budget: budget),
            TencentQuoteSource(budget: budget)
        ], failurePolicy: SourceFailurePolicy())
        let eventSources: [any MarketEventSource] = [
            CLSTelegraphSource(budget: budget),
            EastmoneyNewsSource(budget: budget),
            XueqiuUnavailableSource(),
            ThePaperNewsSource(budget: budget),
            GovCNPolicySource(budget: budget),
            MIITUnavailableSource(),
            CNInfoAnnouncementSource(budget: budget),
            EastmoneyDragonTigerSource(budget: budget)
        ]
        let tagger = try? SectorTagger(bundle: .main)
        let dependencies = StockMonitorRuntimeDependencies(
            store: store,
            requestBudget: budget,
            quoteProvider: quoteProvider,
            minuteHistorySource: EastmoneyMinuteHistorySource(budget: budget),
            dailyHistorySource: EastmoneyDailyHistorySource(budget: budget),
            fundamentalsSource: EastmoneyFundamentalsSource(budget: budget),
            moneyFlowSource: EastmoneyMoneyFlowSource(budget: budget, maximumSymbols: 50),
            marketCoverageSource: EastmoneyMarketScanSource(budget: budget,
                maximumPages: configuration.marketScanMaximumPages,
                maximumSecurities: configuration.marketScanMaximumSecurities),
            fullMarketCoverageSource: EastmoneyMarketScanSource(budget: budget,
                maximumPages: configuration.fullMarketScanMaximumPages,
                maximumSecurities: configuration.fullMarketScanMaximumSecurities),
            eventSources: eventSources,
            sectorTagger: tagger,
            limitSource: LocalDailyLimitSource(),
            backupCipher: AuthenticatedBackupCipher(),
            alertDelivery: defaultAlertDelivery())
        return assemble(configuration: configuration, dependencies: dependencies)
    }

    public static func assemble(configuration: StockMonitorRuntimeConfiguration,
                                 dependencies: StockMonitorRuntimeDependencies,
                                 now: @escaping @Sendable () -> Date = { Date() }) -> StockMonitorFunctionalRuntime {
        let processor = EventProcessor(policy: configuration.eventPolicy, sectorTagger: dependencies.sectorTagger)
        let flowProvider: (any MoneyFlowProviding)? = {
            guard configuration.moneyFlowEnabled, let source = dependencies.moneyFlowSource else { return nil }
            return CachingMoneyFlowProvider(upstream: source,
                maximumSymbols: configuration.moneyFlowMaximumSymbolsPerRefresh,
                minimumRefreshInterval: configuration.moneyFlowRefreshInterval,
                maximumAge: configuration.moneyFlowMaximumAge, now: now)
        }()
        let coverageProvider: (any MarketCoverageProviding)? = {
            guard configuration.marketScanEnabled, let source = dependencies.marketCoverageSource else { return nil }
            return CachingMarketCoverageProvider(upstream: source,
                minimumRefreshInterval: configuration.marketScanRefreshInterval, now: now)
        }()
        let fullCoverageProvider: (any MarketCoverageProviding)? = {
            guard configuration.fullMarketScanEnabled,
                  let source = dependencies.fullMarketCoverageSource else { return nil }
            return CachingMarketCoverageProvider(upstream: source,
                minimumRefreshInterval: configuration.fullMarketScanRefreshInterval, now: now)
        }()

        let llmClient: (any EventLLMEnrichmentClient)? = dependencies.eventLLMClient ?? makeLLMClient(configuration)
        let llmReadiness = eventLLMReadiness(configuration: configuration, client: llmClient)
        let eventEnricher: EventLLMEnricher? = llmReadiness.enabled
            ? EventLLMEnricher(client: llmClient,
                config: EventLLMEnrichmentConfig(enabled: true,
                    tiers: [5: .full, 4: .full, 3: .conditional, 2: .rulesOnly, 1: .rulesOnly],
                    conditionalRequiresMissingMetadata: true,
                    keyProvider: configuration.eventLLMKeyProvider),
                sourcePriority: configuration.eventPolicy.sourcePriority)
            : nil
        let collector = EventCollector(store: dependencies.store, sources: dependencies.eventSources,
            processor: processor, maximumPerSource: configuration.maximumEventsPerSource,
            enricher: eventEnricher)
        let engine = LiveEngine(store: dependencies.store, source: dependencies.quoteProvider,
            historicalSource: dependencies.minuteHistorySource,
            requestBudget: dependencies.requestBudget,
            limitSource: dependencies.limitSource ?? LocalDailyLimitSource(),
            moneyFlowSource: flowProvider, marketCoverageSource: coverageProvider,
            maximumFlowSymbols: 50)
        let fundamentalService = dependencies.fundamentalsSource.map {
            LocalFundamentalsService(source: $0, store: dependencies.store,
                                     maximumCodes: configuration.maximumFundamentalCodes)
        }
        let analyst = CachedOnDemandAnalyst(store: dependencies.store)
        let backupService = SQLitePortableBackupService(store: dependencies.store, cipher: dependencies.backupCipher)
        let capabilities = StockMonitorRuntimeCapabilities(
            marketScan: availability(configuration.marketScanEnabled, available: dependencies.marketCoverageSource != nil,
                disabled: "Market scan is disabled by configuration.", missing: "No market-coverage provider was injected."),
            moneyFlow: availability(configuration.moneyFlowEnabled, available: dependencies.moneyFlowSource != nil,
                disabled: "Minute money-flow is disabled by configuration.", missing: "No money-flow provider was injected."),
            automaticEventLLM: RuntimeFeatureAvailability(enabled: llmReadiness.enabled, reason: llmReadiness.reason),
            fundamentals: RuntimeFeatureAvailability(enabled: fundamentalService != nil,
                reason: fundamentalService == nil ? "No fundamentals provider was injected." : nil),
            encryptedBackup: backupAvailability(dependencies.backupCipher),
            markdownAndPDFReports: RuntimeFeatureAvailability(enabled: true),
            alertDelivery: RuntimeFeatureAvailability(enabled: dependencies.alertDelivery != nil,
                reason: dependencies.alertDelivery == nil ? "No alert-delivery adapter was injected." : nil))
        return StockMonitorFunctionalRuntime(configuration: configuration,
            dependencies: dependencies, engine: engine, eventCollector: collector,
            eventProcessor: processor, fullMarketCoverageProvider: fullCoverageProvider,
            fundamentals: fundamentalService,
            cachedAnalyst: analyst, backupService: backupService, capabilities: capabilities)
    }

    private static func makeLLMClient(_ configuration: StockMonitorRuntimeConfiguration) -> (any EventLLMEnrichmentClient)? {
        guard let endpoint = configuration.eventLLMEndpoint,
              let model = configuration.eventLLMModelID, !model.isEmpty else { return nil }
        return try? URLSessionEventLLMEnrichmentClient(endpoint: endpoint, modelID: model)
    }

    private static func eventLLMReadiness(configuration: StockMonitorRuntimeConfiguration,
                                          client: (any EventLLMEnrichmentClient)?) -> (enabled: Bool, reason: String?) {
        guard configuration.automaticTieredEventEnrichmentRequested else {
            return (false, "Automatic event enrichment was explicitly disabled.")
        }
        guard let endpoint = configuration.eventLLMEndpoint,
              endpoint.scheme?.lowercased() == "https", endpoint.host != nil else {
            return (false, "Configure a valid HTTPS LLM endpoint first.")
        }
        guard let model = configuration.eventLLMModelID, !model.isEmpty else { return (false, "Configure an LLM model ID first.") }
        guard configuration.eventLLMKeyProvider != nil else { return (false, "Configure a Keychain-backed API-key provider first.") }
        guard client != nil else { return (false, "LLM client configuration is invalid or unavailable.") }
        return (true, nil)
    }

    private static func availability(_ requested: Bool, available: Bool,
                                     disabled: String, missing: String) -> RuntimeFeatureAvailability {
        RuntimeFeatureAvailability(enabled: requested && available,
            reason: !requested ? disabled : (available ? nil : missing))
    }

    private static func backupAvailability(_ cipher: any BackupCipher) -> RuntimeFeatureAvailability {
#if canImport(CryptoKit)
        return RuntimeFeatureAvailability(enabled: true)
#else
        if cipher is AuthenticatedBackupCipher {
            return RuntimeFeatureAvailability(enabled: false,
                reason: "AES-GCM backup encryption requires Apple CryptoKit on this platform.")
        }
        return RuntimeFeatureAvailability(enabled: true)
#endif
    }

    private static func defaultAlertDelivery() -> (any AlertDelivery)? {
#if canImport(UserNotifications)
        return AppleNotificationAlertDelivery()
#else
        return nil
#endif
    }
}

/// Stable, concise public name for the core service composition factory.
public typealias FunctionalServiceFactory = StockMonitorFunctionalRuntimeFactory

public struct LocalEventReportService: Sendable {
    private let store: SQLiteMonitorStore
    private let processor: EventProcessor

    public init(store: SQLiteMonitorStore, processor: EventProcessor = EventProcessor()) {
        self.store = store
        self.processor = processor
    }

    public func build(morning: ReportWindow, midday: ReportWindow,
                      sourceStatuses: [EventSourceStatus] = [],
                      generatedAt: Date = Date()) async throws -> ReportModel {
        let start = min(morning.start, midday.start)
        let end = max(morning.end, midday.end)
        let events: [MarketEvent]
        if start < end {
            events = try await store.fetchEvents(from: start, to: end)
        } else {
            events = []
        }
        let calendar = Self.chinaCalendar()
        let days = Set(events.map { calendar.startOfDay(for: $0.publishedAt ?? $0.fetchedAt) }).sorted()
        let clusters = days.flatMap { processor.summary(events: events, day: $0, calendar: calendar,
                                                         generatedAt: generatedAt).clusters }
        let health: SourceHealthSnapshot?
        if start < end {
            let firstDay = calendar.startOfDay(for: start)
            let lastDay = calendar.startOfDay(for: end.addingTimeInterval(-0.001))
            health = try await store.fetchSourceHealth(from: firstDay, through: lastDay)
        } else {
            health = nil
        }
        return ReportBuilder().build(ReportInput(morning: morning, midday: midday,
            events: events, clusters: clusters, sourceStatuses: sourceStatuses,
            health: health, generatedAt: generatedAt))
    }

    private static func chinaCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }
}

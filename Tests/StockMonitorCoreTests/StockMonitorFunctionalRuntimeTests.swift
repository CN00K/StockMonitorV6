import Foundation
import XCTest
@testable import StockMonitorCore

final class StockMonitorFunctionalRuntimeTests: XCTestCase {
    func testAssemblyRunsApprovedTierPolicyOnlyWithEndpointModelAndKeyProvider() async throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let llm = RecordingEventLLMClient()
        let events = [
            event(source: "gov", item: "p1", title: "Policy one", date: date),
            event(source: "miit", item: "p2", title: "Policy two", date: date),
            event(source: "cls", item: "p3", title: "Market event three", date: date),
            event(source: "eastmoney", item: "p4", title: "Market event four", date: date),
            event(source: "xueqiu", item: "p5", title: "Market event five", date: date)
        ]
        let runtime = makeRuntime(configuration: StockMonitorRuntimeConfiguration(
            appGroupIdentifier: nil, marketScanEnabled: false, moneyFlowEnabled: false,
            eventLLMEndpoint: URL(string: "https://llm.example.test/v1/chat/completions"),
            eventLLMModelID: "test-model", eventLLMKeyProvider: FixedEventAPIKeyProvider()),
            eventSource: FixedEventSource(events: events), eventLLMClient: llm)

        let capabilities = await runtime.capabilities
        XCTAssertTrue(capabilities.automaticEventLLM.enabled)
        let report = await runtime.refreshEvents(since: date.addingTimeInterval(-60))
        XCTAssertNil(report.storageError)
        XCTAssertEqual(report.receivedCount, 5)
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 3, "P1/P2 always enrich; P3 is conditional; P4/P5 are rules-only")
        let morning = ReportWindow.morning(start: date, end: date.addingTimeInterval(3_600))
        let midday = ReportWindow.midday(start: date.addingTimeInterval(3_600), end: date.addingTimeInterval(7_200))
        let localReport = try await runtime.buildEventReport(morning: morning, midday: midday, generatedAt: date)
        XCTAssertTrue(localReport.markdown().contains("# 本地资讯时段报告"))
        XCTAssertTrue(try LocalReportExporter.export(report: localReport).starts(with: Data("%PDF-1.4".utf8)))
    }

    func testMissingKeyProviderLeavesAutomaticEnrichmentInactive() async throws {
        let llm = RecordingEventLLMClient()
        let date = Date(timeIntervalSince1970: 1_800_000_100)
        let runtime = makeRuntime(configuration: StockMonitorRuntimeConfiguration(
            appGroupIdentifier: nil, marketScanEnabled: false, moneyFlowEnabled: false,
            eventLLMEndpoint: URL(string: "https://llm.example.test/v1/chat/completions"),
            eventLLMModelID: "test-model", eventLLMKeyProvider: nil),
            eventSource: FixedEventSource(events: [event(source: "gov", item: "one", title: "Policy", date: date)]),
            eventLLMClient: llm)

        let capabilities = await runtime.capabilities
        XCTAssertFalse(capabilities.automaticEventLLM.enabled)
        XCTAssertNotNil(capabilities.automaticEventLLM.reason)
        _ = await runtime.refreshEvents(since: date.addingTimeInterval(-60))
        let callCount = await llm.callCount
        XCTAssertEqual(callCount, 0)
    }

    func testDefaultFactoryBuildsOptionalBoundedDecoratorsWithoutStartingRequests() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-default-\(UUID().uuidString)")
        let runtime = FunctionalServiceFactory.makeDefault(configuration: .init(
            databaseURL: directory.appendingPathComponent("monitor.sqlite"), appGroupIdentifier: nil))
        let engine = runtime.engine
        let store = runtime.store
        _ = store
        let initialState = await engine.state()
        XCTAssertEqual(initialState.phase, .closed)
        let capabilities = await runtime.capabilities
        XCTAssertTrue(capabilities.marketScan.enabled)
        XCTAssertTrue(capabilities.moneyFlow.enabled)
        XCTAssertFalse(capabilities.automaticEventLLM.enabled)
        XCTAssertTrue(capabilities.fundamentals.enabled)
        XCTAssertTrue(capabilities.markdownAndPDFReports.enabled)
#if canImport(CryptoKit)
        XCTAssertTrue(capabilities.encryptedBackup.enabled)
#else
        XCTAssertFalse(capabilities.encryptedBackup.enabled)
#endif
    }

    func testFullMarketScanIsExplicitAndCachedForConfiguredInterval() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let source = RuntimeCountingMarketCoverageSource(timestamp: now)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-full-scan-\(UUID().uuidString)")
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("monitor.sqlite"),
                                       appGroupIdentifier: nil)
        let configuration = StockMonitorRuntimeConfiguration(appGroupIdentifier: nil,
            marketScanEnabled: false, fullMarketScanRefreshInterval: 24 * 60 * 60,
            moneyFlowEnabled: false)
        let runtime = StockMonitorFunctionalRuntimeFactory.assemble(configuration: configuration,
            dependencies: StockMonitorRuntimeDependencies(store: store,
                requestBudget: RequestBudget.standard(), quoteProvider: EmptyQuoteProvider(),
                fullMarketCoverageSource: source), now: { now })

        let callsBeforeExplicitAction = await source.callCount
        XCTAssertEqual(callsBeforeExplicitAction, 0)
        let firstValue: MarketCoverageSnapshot? = try await runtime.fetchFullMarketCoverage()
        let secondValue: MarketCoverageSnapshot? = try await runtime.fetchFullMarketCoverage()
        let first = try XCTUnwrap(firstValue)
        let second = try XCTUnwrap(secondValue)
        let callsAfterTwoActions = await source.callCount
        XCTAssertEqual(callsAfterTwoActions, 1)
        XCTAssertEqual(first.summary.reportedTotalCount, 1)
        XCTAssertEqual(second.status.requestCount, 0)
        XCTAssertEqual(second.sampleDistribution, first.sampleDistribution)
    }

    func testDefaultMarketScanConfigurationUsesFifteenMinuteCacheAndBoundedCaps() {
        let configuration = StockMonitorRuntimeConfiguration()
        XCTAssertEqual(configuration.marketScanRefreshInterval, 15 * 60)
        XCTAssertEqual(configuration.fullMarketScanRefreshInterval, 15 * 60)
        XCTAssertEqual(configuration.marketScanMaximumPages, 10)
        XCTAssertEqual(configuration.marketScanMaximumSecurities, 1_000)
        XCTAssertEqual(configuration.fullMarketScanMaximumPages, 60)
        XCTAssertEqual(configuration.fullMarketScanMaximumSecurities, 6_000)
    }

    private func makeRuntime(configuration: StockMonitorRuntimeConfiguration,
                             eventSource: any MarketEventSource,
                             eventLLMClient: (any EventLLMEnrichmentClient)?) -> StockMonitorFunctionalRuntime {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-test-\(UUID().uuidString)")
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("monitor.sqlite"),
                                       appGroupIdentifier: nil)
        let budget = RequestBudget.standard()
        let dependencies = StockMonitorRuntimeDependencies(store: store,
            requestBudget: budget, quoteProvider: EmptyQuoteProvider(),
            eventSources: [eventSource], eventLLMClient: eventLLMClient,
            backupCipher: AuthenticatedBackupCipher())
        return StockMonitorFunctionalRuntimeFactory.assemble(configuration: configuration,
                                                               dependencies: dependencies)
    }

    private func event(source: String, item: String, title: String, date: Date) -> MarketEvent {
        MarketEvent(kind: .news, sourceID: source, sourceItemID: item, title: title,
            publishedAt: date, fetchedAt: date, providerTimestampVerified: true,
            priority: 1, impactScope: .unknown)
    }
}

private struct EmptyQuoteProvider: MarketDataProviding {
    func fetch(codes: [String], indices: [MarketIndex]) async -> MarketDataBatch {
        MarketDataBatch(quotes: [], indexQuotes: [], sourceStatuses: [])
    }
}

private actor RuntimeCountingMarketCoverageSource: MarketCoverageProviding {
    private(set) var callCount = 0
    private let timestamp: Date

    init(timestamp: Date) { self.timestamp = timestamp }

    func fetchCoverage() async throws -> MarketCoverageSnapshot {
        callCount += 1
        let quote = EastmoneyScanQuote(code: "600000", name: "fixture", market: nil,
            price: nil, changePercent: 1, change: nil, volume: nil, amount: nil,
            turnover: nil, pe: nil, volumeRatio: nil, totalMarketValue: nil,
            mainNetFlow: nil, providerTimestamp: timestamp, raw: [:])
        let distribution = MarketScanDistribution.summarize(quotes: [quote])
        let summary = MarketScanSummary(up: 1, flat: 0, down: 0, amount: nil,
            mainNetFlow: nil, limitUp: nil, limitDown: nil, brokenSeal: nil,
            reportedTotalCount: 1, sampleCoverageFraction: 1,
            changeBuckets: distribution?.buckets, unavailableReason: "limit fields unknown")
        let status = SourceStatus(sourceID: "runtime-full-scan-fixture", fetchedAt: timestamp,
            providerTimestamp: timestamp, requestedCount: 1, returnedCount: 1, requestCount: 1)
        return MarketCoverageSnapshot(summary: summary, topQuotes: [quote],
            sampleDistribution: distribution, status: status)
    }
}

private struct FixedEventSource: MarketEventSource {
    let identifier = "runtime-test-events"
    let events: [MarketEvent]

    func fetch(since: Date, limit: Int) async -> EventFetchBatch {
        let selected = events.filter { ($0.publishedAt ?? .distantPast) >= since }.prefix(limit)
        let values = Array(selected)
        return EventFetchBatch(events: values, status: EventSourceStatus(sourceID: identifier,
            fetchedAt: Date(), latestPublishedAt: values.compactMap(\.publishedAt).max(),
            requestedCount: limit, returnedCount: values.count, requestCount: 1,
            successfulRequestCount: 1, candidateRecordCount: values.count, validRecordCount: values.count))
    }
}

private struct FixedEventAPIKeyProvider: EventLLMAPIKeyProvider {
    func apiKey() async -> String? { "fake-test-only-key" }
}

private actor RecordingEventLLMClient: EventLLMEnrichmentClient {
    private(set) var callCount = 0

    func enrich(_ request: EventLLMEnrichmentRequest) async throws -> EventLLMEnrichment {
        callCount += 1
        return EventLLMEnrichment()
    }
}

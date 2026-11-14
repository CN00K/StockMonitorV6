import Foundation
import XCTest
@testable import StockMonitorCore

final class EventLLMEnrichmentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_794_589_800)

    func testTierPolicyP1P2FullP3ConditionalP4P5Never() {
        let config = EventLLMEnrichmentConfig(enabled: true, keyProvider: TestKeyProvider())
        XCTAssertTrue(config.shouldEnrich(event: event(source: "gov"), sourcePriority: { _ in 5 }))
        XCTAssertTrue(config.shouldEnrich(event: event(source: "miit"), sourcePriority: { _ in 4 }))
        XCTAssertTrue(config.shouldEnrich(event: event(source: "cls"), sourcePriority: { _ in 3 }))
        XCTAssertFalse(config.shouldEnrich(event: event(source: "cls", sectors: ["银行"]), sourcePriority: { _ in 3 }))
        XCTAssertFalse(config.shouldEnrich(event: event(source: "thepaper"), sourcePriority: { _ in 2 }))
        XCTAssertFalse(config.shouldEnrich(event: event(source: "xueqiu"), sourcePriority: { _ in 1 }))
    }

    func testAbsentClientOrConfigurationMakesZeroCalls() async throws {
        let client = MockClient(result: EventLLMEnrichment(sectors: ["银行"]))
        let key = TestKeyProvider()
        let noClient = EventLLMEnricher(config: EventLLMEnrichmentConfig(enabled: true, keyProvider: key))
        _ = try await noClient.enrich([event(source: "gov")])
        XCTAssertEqual(client.calls, 0)
        let noConfig = EventLLMEnricher(client: client, config: .disabled)
        _ = try await noConfig.enrich([event(source: "gov")])
        XCTAssertEqual(client.calls, 0)
    }

    func testCallCountAndMetadataEnrichment() async throws {
        let client = MockClient(result: EventLLMEnrichment(sectors: ["银行"], stockCodes: ["600000"],
            impactScope: .sector, priority: 5, promptTokenCount: 10,
            completionTokenCount: 4, totalTokenCount: 14))
        let enricher = EventLLMEnricher(client: client,
            config: EventLLMEnrichmentConfig(enabled: true, keyProvider: TestKeyProvider()))
        let batch = try await enricher.enrichWithUsage([event(source: "gov"), event(source: "thepaper")])
        XCTAssertEqual(client.calls, 1)
        XCTAssertEqual(batch.usage, AnalystUsageLedger(requestCount: 1, promptTokenCount: 10,
            completionTokenCount: 4, totalTokenCount: 14))
        let events = batch.events
        XCTAssertEqual(events[0].sectors, ["银行"])
        XCTAssertEqual(events[0].stockCodes, ["600000"])
        XCTAssertEqual(events[0].impactScope, .sector)
        XCTAssertEqual(events[0].priority, 5)
    }

    func testFailureKeepsOriginalAndCancellationThrows() async throws {
        let failed = MockClient(error: TestError.failed)
        let enricher = EventLLMEnricher(client: failed,
            config: EventLLMEnrichmentConfig(enabled: true, keyProvider: TestKeyProvider()))
        let original = event(source: "gov")
        let unchanged = try await enricher.enrich([original])
        XCTAssertEqual(unchanged, [original])

        let cancelled = MockClient(error: CancellationError())
        let cancelling = EventLLMEnricher(client: cancelled,
            config: EventLLMEnrichmentConfig(enabled: true, keyProvider: TestKeyProvider()))
        do {
            _ = try await cancelling.enrich([original])
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertEqual(cancelled.calls, 1)
        }
    }

    private func event(source: String, sectors: [String] = []) -> MarketEvent {
        MarketEvent(sourceID: source, title: "官方行业事件", fetchedAt: now, priority: 3, sectors: sectors)
    }
}

private enum TestError: Error { case failed }

private final class TestKeyProvider: EventLLMAPIKeyProvider, @unchecked Sendable {
    func apiKey() async -> String? { "test-only-key" }
}

private final class MockClient: EventLLMEnrichmentClient, @unchecked Sendable {
    private(set) var calls = 0
    private let result: EventLLMEnrichment
    private let error: Error?

    init(result: EventLLMEnrichment = EventLLMEnrichment(), error: Error? = nil) {
        self.result = result
        self.error = error
    }

    func enrich(_ request: EventLLMEnrichmentRequest) async throws -> EventLLMEnrichment {
        calls += 1
        if let error { throw error }
        return result
    }
}

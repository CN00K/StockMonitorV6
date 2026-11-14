import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StockMonitorCore

final class CachedOnDemandAnalystTests: XCTestCase {
    func testMissThenHitCallsProviderOnceAndRecordsOneUsage() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CountingAnalystTransport()
        let cached = CachedOnDemandAnalyst(store: store, analyst: OnDemandAnalyst(transport: transport))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let context = fixtureContext(price: 10)
        let configuration = fixtureConfiguration()

        let first = try await cached.analyze(context: context, configuration: configuration,
                                             apiKey: "secret-api-key", at: date)
        let second = try await cached.analyze(context: context, configuration: configuration,
                                              apiKey: "secret-api-key", at: date.addingTimeInterval(60))

        XCTAssertEqual(first, second)
        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 6)
        let key = AnalystResultCacheKey(stockCode: context.stock.code, endpoint: configuration.endpoint,
                                        modelID: configuration.modelID, context: context, at: date)
        let usage = try await store.analystUsage(for: key)
        XCTAssertEqual(usage, AnalystUsageLedger(requestCount: 6, promptTokenCount: 60,
            completionTokenCount: 30, totalTokenCount: 90))
    }

    func testChangedContextIsCacheMiss() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CountingAnalystTransport()
        let cached = CachedOnDemandAnalyst(store: store, analyst: OnDemandAnalyst(transport: transport))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let configuration = fixtureConfiguration()

        _ = try await cached.analyze(context: fixtureContext(price: 10), configuration: configuration,
                                     apiKey: "secret-api-key", at: date)
        _ = try await cached.analyze(context: fixtureContext(price: 11), configuration: configuration,
                                     apiKey: "secret-api-key", at: date)

        let requestCount = await transport.requestCount
        XCTAssertEqual(requestCount, 12)
    }

    func testFailureIsNotCachedOrCounted() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CountingAnalystTransport(fails: true)
        let cached = CachedOnDemandAnalyst(store: store, analyst: OnDemandAnalyst(transport: transport))
        let context = fixtureContext(price: 10)
        let configuration = fixtureConfiguration()
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        do {
            _ = try await cached.analyze(context: context, configuration: configuration,
                                         apiKey: "secret-api-key", at: date)
            XCTFail("expected provider failure")
        } catch { }

        let key = AnalystResultCacheKey(stockCode: context.stock.code, endpoint: configuration.endpoint,
                                        modelID: configuration.modelID, context: context, at: date)
        let cachedResult = try await store.cachedAnalystResult(for: key, now: date)
        let usage = try await store.analystUsage(for: key)
        XCTAssertNil(cachedResult)
        XCTAssertNil(usage)
    }

    func testCredentialsAndEndpointQueryAreAbsentFromDatabase() async throws {
        let (store, directory) = try await makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let transport = CountingAnalystTransport()
        let cached = CachedOnDemandAnalyst(store: store, analyst: OnDemandAnalyst(transport: transport))
        let context = fixtureContext(price: 10)
        let endpoint = URL(string: "https://provider.example/v1/chat")!
        let configuration = OnDemandAnalystConfiguration(endpoint: endpoint, modelID: "model-a")
        let date = Date(timeIntervalSince1970: 1_800_000_000)

        _ = try await cached.analyze(context: context, configuration: configuration,
                                     apiKey: "secret-api-key", at: date)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("db.sqlite"))
        let databaseText = String(decoding: bytes, as: UTF8.self)
        XCTAssertFalse(databaseText.contains("secret-api-key"))
        XCTAssertFalse(databaseText.contains("do-not-store"))
        XCTAssertFalse(databaseText.contains("api_key"))

        let queryKey = AnalystResultCacheKey(stockCode: context.stock.code,
                                             endpoint: URL(string: "https://provider.example/v1/chat?api_key=do-not-store")!,
                                             modelID: configuration.modelID, context: context, at: date)
        let cleanKey = AnalystResultCacheKey(stockCode: context.stock.code,
                                             endpoint: endpoint, modelID: configuration.modelID,
                                             context: context, at: date)
        XCTAssertEqual(queryKey.cacheID, cleanKey.cacheID)
    }

    private func makeStore() async throws -> (SQLiteMonitorStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try await store.open()
        return (store, directory)
    }

    private func fixtureConfiguration() -> OnDemandAnalystConfiguration {
        OnDemandAnalystConfiguration(endpoint: URL(string: "https://provider.example/v1/chat")!, modelID: "model-a")
    }

    private func fixtureContext(price: Double) -> AnalystContext {
        AnalystContext(stock: AnalystStockFacts(code: "600000", name: "测试股", currentPrice: price))
    }
}

private actor CountingAnalystTransport: AnalystTransport {
    private(set) var requestCount = 0
    let fails: Bool

    init(fails: Bool = false) { self.fails = fails }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        if fails { throw URLError(.cannotConnectToHost) }
        let body = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]) ?? [:]
        let messages = body["messages"] as? [[String: Any]] ?? []
        let system = messages.first?["content"] as? String ?? ""
        let content: [String: Any]
        if system.contains("supervisor") {
            content = ["signal": "持有", "confidence": 0.8, "summary": "summary", "risk": "risk"]
        } else if system.contains("specialist") {
            content = ["score": 72, "narrative": "narrative"]
        } else {
            content = ["signal": "持有", "confidence": 0.8, "target_price": NSNull(),
                       "stop_loss_price": NSNull(), "scores": ["technical": 72, "fundamental": 68,
                       "sentiment": 60, "risk": 45], "summary": "summary", "technical": "technical",
                       "fundamental": "fundamental", "sentiment": "sentiment"]
        }
        let result = try JSONSerialization.data(withJSONObject: content)
        let envelope = try JSONSerialization.data(withJSONObject: [
            "choices": [["message": ["content": String(decoding: result, as: UTF8.self)]]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15]
        ])
        return (envelope, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

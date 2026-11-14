import XCTest
@testable import StockMonitorCore
import CSQLite

final class AnalystResultCacheTests: XCTestCase {
    private func key(at date: Date = Date(timeIntervalSince1970: 1_800_000_000), model: String = "model-a", context: AnalystContext? = nil) -> AnalystResultCacheKey {
        let stock = AnalystStockFacts(code: "600000", name: "浦发银行", currentPrice: 10)
        let context = context ?? AnalystContext(stock: stock, history: [AnalystPricePoint(timestamp: date, close: 10)])
        return AnalystResultCacheKey(stockCode: "600000", endpoint: URL(string: "https://api.example.test/v1/analyze?api_key=secret")!, modelID: model, context: context, at: date)
    }

    private func result() -> StrategyResult {
        StrategyResult(signal: "持有", confidence: 0.8, targetPrice: nil, stopLossPrice: nil,
                       scores: .init(technical: 50, fundamental: 50, sentiment: 50, risk: 20),
                       summary: "summary", technical: "technical", fundamental: "fundamental", sentiment: "sentiment")
    }

    func testCacheHitAndIdentityExcludesCredentials() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try await store.open()
        let first = key()
        let secondContext = AnalystContext(stock: AnalystStockFacts(code: "600000", name: "浦发银行", currentPrice: 10), history: [AnalystPricePoint(timestamp: Date(timeIntervalSince1970: 1_800_000_000), close: 10)])
        let second = AnalystResultCacheKey(stockCode: "600000", endpoint: URL(string: "https://api.example.test/v1/analyze?api_key=different")!, modelID: "model-a", context: secondContext, at: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(first.cacheID, second.cacheID)
        try await store.storeAnalystResult(result(), for: first, storedAt: Date(timeIntervalSince1970: 1_800_000_000), expiresAt: Date(timeIntervalSince1970: 1_800_086_400))
        let cached = try await store.cachedAnalystResult(for: second, now: Date(timeIntervalSince1970: 1_800_000_001))
        XCTAssertEqual(cached, result())
    }

    func testCacheMissesForContextAndModelAndExpires() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try await store.open()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        let original = key(at: at)
        try await store.storeAnalystResult(result(), for: original, storedAt: at, expiresAt: at.addingTimeInterval(10))
        let modelMiss = try await store.cachedAnalystResult(for: key(at: at, model: "model-b"), now: at.addingTimeInterval(1))
        XCTAssertNil(modelMiss)
        let changed = AnalystContext(stock: AnalystStockFacts(code: "600000", name: "浦发银行", currentPrice: 11))
        let contextMiss = try await store.cachedAnalystResult(for: key(at: at, context: changed), now: at.addingTimeInterval(1))
        XCTAssertNil(contextMiss)
        let expired = try await store.cachedAnalystResult(for: original, now: at.addingTimeInterval(11))
        XCTAssertNil(expired)
    }

    func testUsageLedgerPreservesUnknownTokensAsNil() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("db.sqlite"))
        try await store.open()
        let cacheKey = key()
        try await store.recordAnalystUsage(for: cacheKey)
        try await store.recordAnalystUsage(for: cacheKey, requestCount: 2, promptTokenCount: 10, completionTokenCount: 4, totalTokenCount: 14)
        let usage = try await store.analystUsage(for: cacheKey)
        XCTAssertEqual(usage, AnalystUsageLedger(requestCount: 3, promptTokenCount: 10, completionTokenCount: 4, totalTokenCount: 14))
    }

    func testVersionOneDatabaseMigratesToCacheSchema() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("old.sqlite").path
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "PRAGMA user_version=1;", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let store = SQLiteMonitorStore(databaseURL: URL(fileURLWithPath: path))
        try await store.open()
        try await store.storeAnalystResult(result(), for: key())
        let cached = try await store.cachedAnalystResult(for: key())
        XCTAssertNotNil(cached)
    }
}

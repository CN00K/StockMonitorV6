import Foundation
import CSQLite
import XCTest
@testable import StockMonitorCore

final class LiveTickStatusTests: XCTestCase {
    func testModelDistinguishesCompletePartialAndEmptyAndPreservesUnknown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(LiveTickStatusRecord(recordedAt: now, operation: .tick,
            dataStatus: .complete, requestedSymbols: 2, returnedSymbols: 2).reconcileOutcome, .unknown)
        XCTAssertEqual(LiveTickStatusRecord(recordedAt: now, operation: .tick,
            dataStatus: .partial, requestedSymbols: 2, returnedSymbols: 1,
            missingSymbols: ["000001"]).missingSymbols, ["000001"])
        XCTAssertEqual(LiveTickStatusRecord(recordedAt: now, operation: .tick,
            dataStatus: .empty, requestedSymbols: 2, returnedSymbols: 0).dataStatus, .empty)
    }

    func testSQLitePersistsReconcileOutcomesWithoutQuoteBodiesAndEnforcesCap() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("status-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("monitor.sqlite"),
            appGroupIdentifier: nil, maximumLiveTickStatusRows: 3)
        try await store.open()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<5 {
            try await store.recordLiveTickStatus(LiveTickStatusRecord(
                recordedAt: now.addingTimeInterval(TimeInterval(index)), operation: .reconcile,
                dataStatus: index == 0 ? .empty : .complete, requestedSymbols: 2,
                returnedSymbols: index == 0 ? 0 : 2,
                missingSymbols: index == 0 ? ["600000", "000001"] : [],
                reconcileOutcome: [.unknown, .success, .failure, .unknown, .success][index]))
        }
        let records = try await store.fetchLiveTickStatuses(limit: 20)
        XCTAssertEqual(records.count, 3)
        XCTAssertEqual(records.map(\.reconcileOutcome), [.success, .unknown, .failure])
        XCTAssertEqual(records.last?.missingSymbols, [])
    }

    func testLegacyDatabaseMigratesStatusTable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("status-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("monitor.sqlite")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &raw), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(raw, "PRAGMA user_version=4;", nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(raw), SQLITE_OK)

        let store = SQLiteMonitorStore(databaseURL: url, appGroupIdentifier: nil)
        try await store.open()
        let record = LiveTickStatusRecord(recordedAt: Date(timeIntervalSince1970: 1_800_000_000),
            operation: .tick, dataStatus: .partial, requestedSymbols: 2, returnedSymbols: 1,
            missingSymbols: ["000001"])
        try await store.recordLiveTickStatus(record)
        let records = try await store.fetchLiveTickStatuses(limit: 10)
        XCTAssertEqual(records, [record])
    }
}

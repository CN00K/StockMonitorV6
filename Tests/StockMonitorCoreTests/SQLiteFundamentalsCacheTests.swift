import CSQLite
import Foundation
import XCTest
@testable import StockMonitorCore

final class SQLiteFundamentalsCacheTests: XCTestCase {
    func testV3DatabaseMigratesToV6AndStoresLatestFundamentalsWithoutFillingUnknowns() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-fundamentals-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("monitor.sqlite")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &raw), SQLITE_OK)
        let legacySQL = """
        CREATE TABLE sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, started_at REAL NOT NULL, ended_at REAL,
          tick_count INTEGER NOT NULL DEFAULT 0, request_count INTEGER NOT NULL DEFAULT 0,
          prompt_tokens INTEGER, completion_tokens INTEGER, total_tokens INTEGER);
        PRAGMA user_version=3;
        """
        XCTAssertEqual(sqlite3_exec(raw, legacySQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(raw), SQLITE_OK)

        let store = SQLiteMonitorStore(databaseURL: databaseURL, appGroupIdentifier: nil)
        try await store.open()
        let older = EastmoneyFundamentalSnapshot(code: "600000", name: "older", pb: 0.5,
            unavailableFields: ["peTTM", "psTTM"], fetchedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = EastmoneyFundamentalSnapshot(code: "600000", name: "newer",
            peDynamic: 6.4, pb: 0.46, unavailableFields: ["peTTM", "psTTM"],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_100))
        let missingIdentity = EastmoneyFundamentalSnapshot(code: nil, name: "unknown identity")
        try await store.upsertFundamentalSnapshots([older, newer, missingIdentity])

        let latest = try await store.latestFundamentalSnapshots(codes: ["600000", "000001"])
        XCTAssertEqual(latest.count, 1)
        XCTAssertEqual(latest[0].name, "newer")
        XCTAssertEqual(latest[0].pb, 0.46)
        XCTAssertEqual(latest[0].peDynamic, 6.4)
        XCTAssertNil(latest[0].roe)
        XCTAssertTrue(latest[0].unavailableFields.contains("psTTM"))

        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &check), SQLITE_OK)
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &statement, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(statement, 0), 6)
        sqlite3_finalize(statement)
        XCTAssertEqual(sqlite3_close(check), SQLITE_OK)
    }
}

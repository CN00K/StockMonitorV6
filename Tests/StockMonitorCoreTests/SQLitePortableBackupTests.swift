import Foundation
import CSQLite
import XCTest
@testable import StockMonitorCore

final class SQLitePortableBackupTests: XCTestCase {
    func testRoundTripPreservesPortableDataAndSignalReadState() async throws {
        let source = try makeStore("source")
        let target = try makeStore("target")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quote = Quote(code: "600000", name: "Fixture", timestamp: now, price: 10,
                          previousClose: 9.5, open: 9.8, high: 10.2, low: 9.7, volume: 100,
                          sourceID: "fixture", retrievedAt: now)
        let readID = UUID(), unreadID = UUID()
        let read = AlertSignal(id: readID, code: "600000", ruleID: "r", level: .info,
                               title: "read", detail: "", createdAt: now)
        let unread = AlertSignal(id: unreadID, code: "600000", ruleID: "r", level: .warning,
                                 title: "unread", detail: "", createdAt: now.addingTimeInterval(1))
        try await source.setWatchCodes(["600000"])
        try await source.insertQuotes([quote])
        try await source.appendSignals([read, unread])
        try await source.markSignalRead(readID, at: now.addingTimeInterval(2))
        let backup = try await source.exportPortableBackupSnapshot(exportedAt: now)
        try backup.snapshot.validate()
        try await target.importPortableBackupSnapshot(backup)
        let roundTrip = try await target.exportPortableBackupSnapshot(exportedAt: now)
        XCTAssertEqual(roundTrip.snapshot, backup.snapshot)
        XCTAssertEqual(roundTrip.signalReadAt, backup.signalReadAt)
    }

    func testPortableBackupRoundTripsMinuteAndDailyHistory() async throws {
        let source = try makeStore("history-source", minuteRows: 10, dailyRows: 10, historyBytes: 100_000)
        let target = try makeStore("history-target")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        try await source.setWatchCodes(["600000"])
        let minute = MinuteBar(code: "600000", name: "Fixture", timestamp: now,
            open: 10, close: 10.1, high: 10.2, low: 9.9, volume: 100, amount: 1_000,
            previousClose: 9.8, sourceID: "fixture", fetchedAt: now)
        let daily = DailyBar(code: "600000", name: "Fixture", tradeDate: now,
            open: 10, high: 10.3, low: 9.8, close: 10.1, volume: 1000, amount: 10_000,
            sourceID: "fixture", fetchedAt: now)
        try await source.commitReconciliation(bars: [minute], signals: [])
        try await source.upsertDailyBars([daily])
        let backup = try await source.exportPortableBackupSnapshot(exportedAt: now)
        XCTAssertEqual(backup.snapshot.history?.minuteBars, [minute])
        XCTAssertEqual(backup.snapshot.history?.dailyBars, [daily])
        XCTAssertNil(backup.snapshot.history?.omissionReason)
        try await target.importPortableBackupSnapshot(backup)
        let restored = try await target.exportPortableBackupSnapshot(exportedAt: now)
        XCTAssertEqual(restored.snapshot.history, backup.snapshot.history)
    }

    func testPortableBackupDisclosesHistoryRowLimitWithoutPartialData() async throws {
        let store = try makeStore("history-cap", minuteRows: 1, dailyRows: 10, historyBytes: 100_000)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let bars = (0..<2).map { index in
            MinuteBar(code: "600000", name: "Fixture", timestamp: now.addingTimeInterval(Double(index)),
                open: 10, close: 10, high: 10, low: 10, volume: 1, amount: nil,
                previousClose: 10, sourceID: "fixture", fetchedAt: now)
        }
        try await store.commitReconciliation(bars: bars, signals: [])
        let backup = try await store.exportPortableBackupSnapshot(exportedAt: now)
        XCTAssertTrue(backup.snapshot.history?.minuteBars.isEmpty == true)
        XCTAssertEqual(backup.snapshot.history?.omissionReason, "minute_bars row cap exceeded (1)")
    }

    func testLegacySnapshotWithoutHistoryDecodes() throws {
        let snapshot = PortableBackupSnapshot(exportedAt: Date(timeIntervalSince1970: 1_700_000_000), watchCodes: ["600000"])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(snapshot)) as? [String: Any])
        object.removeValue(forKey: "history")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacy = try decoder.decode(PortableBackupSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(legacy.history)
        try legacy.validate()
    }

    func testInvalidSnapshotDoesNotChangeDatabaseAndRepeatedImportIsSafe() async throws {
        let store = try makeStore("atomic")
        let exportedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try await store.setWatchCodes(["600000"])
        let before = try await store.exportPortableBackupSnapshot(exportedAt: exportedAt)
        let invalid = PortableBackupSnapshot(watchCodes: ["600000"], watchRules: [
            WatchRule(id: "r", code: "999999", title: "bad", detail: "", condition: .priceAtLeast(1))
        ])
        XCTAssertThrowsError(try invalid.validate())
        do {
            try await store.importPortableBackupSnapshot(invalid)
            XCTFail("invalid snapshot was imported")
        } catch { }
        let unchanged = try await store.exportPortableBackupSnapshot(exportedAt: exportedAt)
        XCTAssertEqual(unchanged.snapshot, before.snapshot)

        let valid = PortableBackupSnapshot(exportedAt: exportedAt, watchCodes: ["600000"],
                                           history: PortableBackupHistory())
        try await store.importPortableBackupSnapshot(valid)
        try await store.importPortableBackupSnapshot(valid)
        let repeated = try await store.exportPortableBackupSnapshot(exportedAt: exportedAt)
        XCTAssertEqual(repeated.snapshot, valid)
    }

    func testHistoryOmissionReasonIsPreservedAndDoesNotPartiallyReplaceLocalBars() async throws {
        let source = try makeStore("history-omitted-source", minuteRows: 1, dailyRows: 100, historyBytes: 100_000)
        let target = try makeStore("history-omitted-target")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let sourceBars = (0..<2).map { index in
            MinuteBar(code: "600000", name: "Source", timestamp: now.addingTimeInterval(Double(index)),
                open: 10, close: 10, high: 10, low: 10, volume: 1, amount: nil,
                previousClose: 10, sourceID: "source", fetchedAt: now)
        }
        let targetBar = MinuteBar(code: "600000", name: "Target", timestamp: now.addingTimeInterval(100),
            open: 11, close: 11, high: 11, low: 11, volume: 1, amount: nil,
            previousClose: 10, sourceID: "target", fetchedAt: now)
        try await source.commitReconciliation(bars: sourceBars, signals: [])
        try await target.commitReconciliation(bars: [targetBar], signals: [])
        let backup = try await source.exportPortableBackupSnapshot(exportedAt: now)
        XCTAssertEqual(backup.snapshot.history?.omissionReason, "minute_bars row cap exceeded (1)")
        XCTAssertTrue(backup.snapshot.history?.minuteBars.isEmpty == true)

        try await target.importPortableBackupSnapshot(backup)
        let restored = try await target.exportPortableBackupSnapshot(exportedAt: now)
        XCTAssertEqual(restored.snapshot.history?.minuteBars, [targetBar])
        XCTAssertNil(restored.snapshot.history?.omissionReason)
    }

    func testLegacySessionsSchemaMigratesAndPersistsUsageCounters() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-session-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("monitor.sqlite")
        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open(databaseURL.path, &raw), SQLITE_OK)
        let legacySQL = "CREATE TABLE sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, started_at REAL NOT NULL, ended_at REAL); PRAGMA user_version=2;"
        XCTAssertEqual(sqlite3_exec(raw, legacySQL, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_close(raw), SQLITE_OK)

        let store = SQLiteMonitorStore(databaseURL: databaseURL, appGroupIdentifier: nil)
        try await store.open()
        try await store.beginSession(at: Date(timeIntervalSince1970: 1_800_000_000))
        try await store.recordSessionActivity(ticks: 3, requests: 9)
        try await store.recordSessionActivity(ticks: 1, requests: 6,
            promptTokens: 60, completionTokens: 30, totalTokens: 90)
        let usage = try await store.latestSessionUsage()
        XCTAssertEqual(usage, MonitorSessionUsage(tickCount: 4, requestCount: 15,
            promptTokenCount: 60, completionTokenCount: 30, totalTokenCount: 90))
        try await store.endSession(at: Date(timeIntervalSince1970: 1_800_000_060))
        try await store.recordSessionActivity(ticks: 5, requests: 12)
        let afterSessionClosed = try await store.latestSessionUsage()
        XCTAssertEqual(afterSessionClosed, usage)
    }

    func testUnavailableConfiguredAppGroupUsesPrivateApplicationSupportFallback() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-app-group-fallback-\(UUID().uuidString)", isDirectory: true)
        let applicationSupport = root.appendingPathComponent("Application Support", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let missingGroup = "group.cn00k.stockmonitorv6.test.missing"
        let store = SQLiteMonitorStore(appGroupIdentifier: missingGroup,
                                       applicationSupportDirectoryURL: applicationSupport)

        XCTAssertEqual(store.storageMode,
                       .privateApplicationSupport(unavailableAppGroupIdentifier: missingGroup))
        try await store.open()
        try await store.setWatchCodes(["600000"])
        let restored = try await store.restoreState()

        XCTAssertEqual(restored.watchCodes, ["600000"])
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: applicationSupport.appendingPathComponent("Monitor.sqlite").path))
    }

    private func makeStore(_ name: String, minuteRows: Int = 100_000, dailyRows: Int = 100_000,
                           historyBytes: Int = 16 * 1_024 * 1_024) throws -> SQLiteMonitorStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("sqlite-backup-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("monitor.sqlite"), appGroupIdentifier: nil,
                                  maximumPortableHistoryMinuteRows: minuteRows,
                                  maximumPortableHistoryDailyRows: dailyRows,
                                  maximumPortableHistoryBytes: historyBytes)
    }
}

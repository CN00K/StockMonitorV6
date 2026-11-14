import Foundation
import XCTest
@testable import StockMonitorCore

final class SQLitePortableBackupServiceTests: XCTestCase {
    func testEncryptedServiceRoundTripKeepsSignalReadStateAndRestoresAtomically() async throws {
        let source = try makeStore("source")
        let target = try makeStore("target")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let signal = AlertSignal(code: "600000", ruleID: "r", level: .warning,
            title: "sample", detail: "local", createdAt: date)
        try await source.setWatchCodes(["600000"])
        try await source.appendSignals([signal])
        try await source.markSignalRead(signal.id, at: date.addingTimeInterval(5))
        let key = Data(repeating: 7, count: 32)
        let exporter = SQLitePortableBackupService(store: source, cipher: TestOnlyReversibleCipher())
        let importer = SQLitePortableBackupService(store: target, cipher: TestOnlyReversibleCipher())

        let file = try await exporter.export(using: key, at: date)
        XCTAssertTrue(String(decoding: file, as: UTF8.self).contains(EncryptedSQLitePortableBackup.formatIdentifier))
        try await importer.restore(file, using: key)
        let restored = try await target.exportPortableBackupSnapshot(exportedAt: date)
        XCTAssertEqual(restored.snapshot.watchCodes, ["600000"])
        XCTAssertEqual(restored.snapshot.signals, [signal])
        XCTAssertEqual(restored.signalReadAt[signal.id], date.addingTimeInterval(5))

        let before = restored
        do {
            try await importer.restore(Data("not a backup".utf8), using: key)
            XCTFail("malformed backup was accepted")
        } catch { }
        let after = try await target.exportPortableBackupSnapshot(exportedAt: date)
        XCTAssertEqual(after, before)
    }

    func testKeyLengthAndFileSizeAreValidated() async throws {
        let store = try makeStore("bounds")
        let service = SQLitePortableBackupService(store: store,
            cipher: TestOnlyReversibleCipher(), maximumFileBytes: 1_024,
            maximumPayloadBytes: 1_024)
        do {
            _ = try await service.export(using: Data([1, 2, 3]))
            XCTFail("invalid key length should fail")
        } catch let error as BackupSecurityError {
            XCTAssertEqual(error, .invalidKeyLength)
        }
        do {
            try await service.restore(Data(repeating: 0, count: 1_025), using: Data(repeating: 1, count: 32))
            XCTFail("oversized file should fail")
        } catch let error as SQLitePortableBackupServiceError {
            XCTAssertEqual(error, .fileTooLarge)
        }
    }

    private func makeStore(_ name: String) throws -> SQLiteMonitorStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sqlite-encrypted-backup-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("monitor.sqlite"),
                                  appGroupIdentifier: nil)
    }
}

/// Deliberately non-cryptographic test double; never used by the application.
private struct TestOnlyReversibleCipher: BackupCipher {
    func encrypt(_ plaintext: Data, using key: Data) throws -> BackupEnvelope {
        guard key.count == 32 else { throw BackupSecurityError.invalidKeyLength }
        return BackupEnvelope(nonce: Data([1]), ciphertext: plaintext, tag: Data([2]))
    }

    func decrypt(_ envelope: BackupEnvelope, using key: Data) throws -> Data {
        guard key.count == 32 else { throw BackupSecurityError.invalidKeyLength }
        guard envelope.version == BackupEnvelope.currentVersion,
              envelope.nonce == Data([1]), envelope.tag == Data([2]) else {
            throw BackupSecurityError.authenticationFailed
        }
        return envelope.ciphertext
    }
}

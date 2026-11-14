import Foundation
import XCTest
@testable import StockMonitorCore

final class PortableBackupCodecTests: XCTestCase {
    func testSnapshotExportImportRoundTripsAllPortableSections() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let quote = Quote(code: "600000", name: "Fixture", timestamp: now, price: 10.5,
                          previousClose: 10, open: 10, high: 11, low: 9.8, volume: 100,
                          sourceID: "fixture", retrievedAt: now)
        let rule = WatchRule(id: "rule-1", code: "600000", title: "Price", detail: "high",
                             condition: .priceAtLeast(10))
        let signal = AlertSignal(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                                 code: "600000", ruleID: rule.id, level: .warning,
                                 title: "Price", detail: "matched", createdAt: now)
        let event = MarketEvent(id: "event-1", kind: .news, sourceID: "fixture",
                                title: "Fixture event", fetchedAt: now, stockCodes: ["600000"])
        let settings = PortableBackupSettings(
            ruleFamilySettings: [RuleFamilySettings(family: .dailyChange, threshold: 3,
                                                     confirmations: 1, cooldownSeconds: 60)],
            lastQuoteTime: now,
            lastQuoteTimeByCode: ["600000": now])
        let snapshot = PortableBackupSnapshot(exportedAt: now, watchCodes: ["600000"],
                                              watchRules: [rule], holdings: [Holding(code: "600000", shares: 10, averageCost: 9.5, updatedAt: now)],
                                              signals: [signal], quotes: [quote], indexQuotes: [],
                                              events: [event], settings: settings)
        let codec = PortableBackupCodec(cipher: TestBackupCipher())
        let data = try codec.export(snapshot, using: Data(repeating: 7, count: 32))

        XCTAssertEqual(try codec.import(data, using: Data(repeating: 7, count: 32)), snapshot)
    }

    func testMalformedAndVersionMismatchAreRejected() throws {
        let codec = PortableBackupCodec(cipher: TestBackupCipher())
        XCTAssertThrowsError(try codec.import(Data("not-json".utf8), using: Data(repeating: 0, count: 32))) { error in
            XCTAssertEqual(error as? PortableBackupCodecError, .malformed)
        }

        let envelope = BackupEnvelope(version: 1, nonce: Data([1]), ciphertext: Data([2]), tag: Data([3]))
        let unsupported = PortableBackupExport(version: 99, envelope: envelope)
        XCTAssertThrowsError(try codec.importRepresentation(unsupported, using: Data(repeating: 0, count: 32))) { error in
            XCTAssertEqual(error as? PortableBackupCodecError, .unsupportedVersion(99))
        }
    }

    func testEncryptionFailureIsReportedWithoutLeakingCipherError() {
        let codec = PortableBackupCodec(cipher: FailingBackupCipher())
        let snapshot = PortableBackupSnapshot(watchCodes: ["600000"])
        XCTAssertThrowsError(try codec.export(snapshot, using: Data(repeating: 0, count: 32))) { error in
            XCTAssertEqual(error as? PortableBackupCodecError, .encryptionFailed)
        }
    }
}

private struct TestBackupCipher: BackupCipher {
    func encrypt(_ plaintext: Data, using key: Data) throws -> BackupEnvelope {
        BackupEnvelope(nonce: Data([1]), ciphertext: plaintext, tag: Data([2]))
    }

    func decrypt(_ envelope: BackupEnvelope, using key: Data) throws -> Data {
        envelope.ciphertext
    }
}

private struct FailingBackupCipher: BackupCipher {
    func encrypt(_ plaintext: Data, using key: Data) throws -> BackupEnvelope {
        throw BackupSecurityError.authenticationFailed
    }

    func decrypt(_ envelope: BackupEnvelope, using key: Data) throws -> Data {
        throw BackupSecurityError.authenticationFailed
    }
}

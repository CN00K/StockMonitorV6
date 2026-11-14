import Foundation
import XCTest
@testable import StockMonitorCore

final class LocalCredentialAndBackupSecurityTests: XCTestCase {
    func testCredentialIdentifierContainsOnlyNonSecretIdentity() {
        let identifier = CredentialIdentifier.llmProviderAPIKey(service: "com.example.StockMonitor")
        XCTAssertEqual(identifier.service, "com.example.StockMonitor")
        XCTAssertEqual(identifier.account, "llm-provider-api-key")
        XCTAssertFalse(String(describing: identifier).contains("secret"))
    }

    func testEmptyCredentialSecretIsRejectedWithoutExposingSecret() {
        let identifier = CredentialIdentifier(service: "fixture", account: "account")
        let error = CredentialStoreError.invalidSecret(identifier)
        XCTAssertEqual(error, .invalidSecret(identifier))
        XCTAssertFalse(error.localizedDescription.contains("Data"))
        XCTAssertFalse(error.localizedDescription.contains("fixture"))
    }

    func testBackupEnvelopeRoundTripsThroughCodable() throws {
        let envelope = BackupEnvelope(version: 1, nonce: Data([1, 2, 3]),
                                      ciphertext: Data([4, 5]), tag: Data([6, 7]))
        let encoded = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(BackupEnvelope.self, from: encoded)
        XCTAssertEqual(decoded, envelope)
    }

    func testFakeCipherExercisesBackupProtocolWithoutPlatformCrypto() throws {
        let cipher = FakeBackupCipher()
        let key = Data(repeating: 7, count: 32)
        let plaintext = Data("offline fixture".utf8)
        let envelope = try cipher.encrypt(plaintext, using: key)
        XCTAssertEqual(try cipher.decrypt(envelope, using: key), plaintext)
    }

    func testAuthenticatedCipherRejectsKeysThatAreNot32Bytes() {
        let cipher = AuthenticatedBackupCipher()
        XCTAssertThrowsError(try cipher.encrypt(Data([1]), using: Data(repeating: 0, count: 31))) { error in
            XCTAssertEqual(error as? BackupSecurityError, .invalidKeyLength)
        }
        XCTAssertThrowsError(try cipher.decrypt(BackupEnvelope(nonce: Data([1]), ciphertext: Data([2]), tag: Data([3])),
                                                 using: Data(repeating: 0, count: 33))) { error in
            XCTAssertEqual(error as? BackupSecurityError, .invalidKeyLength)
        }
    }

    func testAuthenticatedCipherRejectsUnsupportedOrInvalidEnvelope() {
        let cipher = AuthenticatedBackupCipher()
        let key = Data(repeating: 0, count: 32)
        let unsupported = BackupEnvelope(version: 99, nonce: Data([1]), ciphertext: Data([2]), tag: Data([3]))
        XCTAssertThrowsError(try cipher.decrypt(unsupported, using: key)) { error in
            XCTAssertEqual(error as? BackupSecurityError, .unsupportedVersion(99))
        }
        let invalid = BackupEnvelope(nonce: Data(), ciphertext: Data([2]), tag: Data([3]))
        XCTAssertThrowsError(try cipher.decrypt(invalid, using: key)) { error in
            #if canImport(CryptoKit)
            XCTAssertEqual(error as? BackupSecurityError, .invalidEnvelope)
            #else
            XCTAssertEqual(error as? BackupSecurityError, .invalidEnvelope)
            #endif
        }
    }

    #if !canImport(Security)
    func testKeychainAdapterIsExplicitlyUnavailableWithoutSecurityFramework() {
        let identifier = CredentialIdentifier(service: "fixture", account: "llm-provider-api-key")
        XCTAssertThrowsError(try KeychainCredentialStore().read(identifier)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .unavailable(identifier))
        }
    }

    func testKeychainAdapterRejectsEmptySecretBeforePlatformAvailabilityCheck() {
        let identifier = CredentialIdentifier(service: "fixture", account: "llm-provider-api-key")
        XCTAssertThrowsError(try KeychainCredentialStore().write(Data(), to: identifier)) { error in
            XCTAssertEqual(error as? CredentialStoreError, .invalidSecret(identifier))
        }
    }
    #endif

    #if canImport(CryptoKit)
    func testCryptoKitCipherRoundTripsAndAuthenticatesAAD() throws {
        let cipher = AuthenticatedBackupCipher()
        let key = Data(repeating: 9, count: 32)
        let envelope = try cipher.encrypt(Data("backup".utf8), using: key)
        XCTAssertEqual(try cipher.decrypt(envelope, using: key), Data("backup".utf8))
        let tampered = BackupEnvelope(version: 2, nonce: envelope.nonce,
                                      ciphertext: envelope.ciphertext, tag: envelope.tag)
        XCTAssertThrowsError(try cipher.decrypt(tampered, using: key))
    }
    #endif
}

private struct FakeBackupCipher: BackupCipher {
    func encrypt(_ plaintext: Data, using key: Data) throws -> BackupEnvelope {
        guard key.count == 32 else { throw BackupSecurityError.invalidKeyLength }
        return BackupEnvelope(nonce: Data([0]), ciphertext: plaintext, tag: Data([1]))
    }

    func decrypt(_ envelope: BackupEnvelope, using key: Data) throws -> Data {
        guard key.count == 32 else { throw BackupSecurityError.invalidKeyLength }
        guard envelope.version == BackupEnvelope.currentVersion,
              envelope.nonce == Data([0]), envelope.tag == Data([1]) else {
            throw BackupSecurityError.invalidEnvelope
        }
        return envelope.ciphertext
    }
}

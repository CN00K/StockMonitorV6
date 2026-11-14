import Foundation
#if canImport(CryptoKit)
import CryptoKit
#endif

/// A non-secret reference to a stored credential.
public struct CredentialIdentifier: Hashable, Sendable, Codable {
    public let service: String
    public let account: String

    public init(service: String, account: String) {
        self.service = service
        self.account = account
    }
}

public enum CredentialStoreError: Error, Equatable, Sendable, LocalizedError {
    case invalidIdentifier(CredentialIdentifier)
    case invalidSecret(CredentialIdentifier)
    case notFound(CredentialIdentifier)
    case unavailable(CredentialIdentifier)
    case operationFailed(CredentialIdentifier)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier: return "Credential identifier is invalid"
        case .invalidSecret: return "Credential secret is invalid"
        case .notFound: return "Credential was not found"
        case .unavailable: return "Credential storage is unavailable"
        case .operationFailed: return "Credential storage operation failed"
        }
    }
}

/// Stores opaque credential bytes without exposing secrets in its error contract.
public protocol CredentialStore: Sendable {
    func read(_ identifier: CredentialIdentifier) throws -> Data
    func write(_ secret: Data, to identifier: CredentialIdentifier) throws
    func delete(_ identifier: CredentialIdentifier) throws
}

public extension CredentialIdentifier {
    /// The app's existing generic-password Keychain record identity.
    static func llmProviderAPIKey(service: String? = nil) -> CredentialIdentifier {
        CredentialIdentifier(service: service ?? Bundle.main.bundleIdentifier ?? "", account: "llm-provider-api-key")
    }
}

#if canImport(Security)
import Security

/// Apple Keychain adapter for the app's generic-password credential record.
public struct KeychainCredentialStore: CredentialStore {
    public init() {}

    public func read(_ identifier: CredentialIdentifier) throws -> Data {
        try validate(identifier)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.service,
            kSecAttrAccount as String: identifier.account,
            kSecAttrSynchronizable as String: false,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw CredentialStoreError.notFound(identifier) }
            throw CredentialStoreError.operationFailed(identifier)
        }
        guard let data = result as? Data else {
            throw CredentialStoreError.operationFailed(identifier)
        }
        guard !data.isEmpty else { throw CredentialStoreError.invalidSecret(identifier) }
        return data
    }

    public func write(_ secret: Data, to identifier: CredentialIdentifier) throws {
        try validate(identifier)
        guard !secret.isEmpty else { throw CredentialStoreError.invalidSecret(identifier) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.service,
            kSecAttrAccount as String: identifier.account,
            kSecValueData as String: secret,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: identifier.service,
                kSecAttrAccount as String: identifier.account,
                kSecAttrSynchronizable as String: false
            ]
            let update: [String: Any] = [
                kSecValueData as String: secret,
                kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                kSecAttrSynchronizable as String: false
            ]
            guard SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess else {
                throw CredentialStoreError.operationFailed(identifier)
            }
        } else if status != errSecSuccess {
            throw CredentialStoreError.operationFailed(identifier)
        }
    }

    public func delete(_ identifier: CredentialIdentifier) throws {
        try validate(identifier)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: identifier.service,
            kSecAttrAccount as String: identifier.account,
            kSecAttrSynchronizable as String: false
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.operationFailed(identifier)
        }
    }

    private func validate(_ identifier: CredentialIdentifier) throws {
        guard !identifier.service.isEmpty, !identifier.account.isEmpty else {
            throw CredentialStoreError.invalidIdentifier(identifier)
        }
    }
}
#else
/// Explicit unsupported-platform adapter; no secret is retained or reported.
public struct KeychainCredentialStore: CredentialStore {
    public init() {}
    public func read(_ identifier: CredentialIdentifier) throws -> Data {
        throw CredentialStoreError.unavailable(identifier)
    }
    public func write(_ secret: Data, to identifier: CredentialIdentifier) throws {
        guard !secret.isEmpty else { throw CredentialStoreError.invalidSecret(identifier) }
        throw CredentialStoreError.unavailable(identifier)
    }
    public func delete(_ identifier: CredentialIdentifier) throws {
        throw CredentialStoreError.unavailable(identifier)
    }
}
#endif

public enum BackupSecurityError: Error, Equatable, Sendable, LocalizedError {
    case invalidKeyLength
    case invalidEnvelope
    case unsupportedPlatform
    case unsupportedVersion(Int)
    case authenticationFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKeyLength: return "Backup key must be exactly 32 bytes"
        case .invalidEnvelope: return "Backup envelope is invalid"
        case .unsupportedPlatform: return "Authenticated backup encryption is unavailable on this platform"
        case .unsupportedVersion: return "Backup envelope version is unsupported"
        case .authenticationFailed: return "Backup authentication failed"
        }
    }
}

/// Versioned, authenticated backup payload. Components are encoded as base64 by Codable.
public struct BackupEnvelope: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let nonce: Data
    public let ciphertext: Data
    public let tag: Data

    public init(version: Int = BackupEnvelope.currentVersion, nonce: Data, ciphertext: Data, tag: Data) {
        self.version = version
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }
}

public protocol BackupCipher: Sendable {
    func encrypt(_ plaintext: Data, using key: Data) throws -> BackupEnvelope
    func decrypt(_ envelope: BackupEnvelope, using key: Data) throws -> Data
}

public struct AuthenticatedBackupCipher: BackupCipher {
    public init() {}

    public func encrypt(_ plaintext: Data, using key: Data) throws -> BackupEnvelope {
        guard key.count == 32 else { throw BackupSecurityError.invalidKeyLength }
        #if canImport(CryptoKit)
        let symmetricKey = SymmetricKey(data: key)
        let aad = Self.associatedData(for: BackupEnvelope.currentVersion)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: symmetricKey, authenticating: aad)
            return BackupEnvelope(version: BackupEnvelope.currentVersion,
                                  nonce: Data(sealed.nonce), ciphertext: sealed.ciphertext,
                                  tag: sealed.tag)
        } catch {
            throw BackupSecurityError.authenticationFailed
        }
        #else
        throw BackupSecurityError.unsupportedPlatform
        #endif
    }

    public func decrypt(_ envelope: BackupEnvelope, using key: Data) throws -> Data {
        guard key.count == 32 else { throw BackupSecurityError.invalidKeyLength }
        guard envelope.version == BackupEnvelope.currentVersion,
              !envelope.nonce.isEmpty, !envelope.tag.isEmpty else {
            if envelope.version != BackupEnvelope.currentVersion {
                throw BackupSecurityError.unsupportedVersion(envelope.version)
            }
            throw BackupSecurityError.invalidEnvelope
        }
        #if canImport(CryptoKit)
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: envelope.nonce),
                                            ciphertext: envelope.ciphertext, tag: envelope.tag)
            return try AES.GCM.open(box, using: SymmetricKey(data: key),
                                    authenticating: Self.associatedData(for: envelope.version))
        } catch {
            throw BackupSecurityError.authenticationFailed
        }
        #else
        throw BackupSecurityError.unsupportedPlatform
        #endif
    }

    public static func associatedData(for version: Int) -> Data {
        Data("StockMonitorCore.AuthenticatedBackup.v\(version)".utf8)
    }
}

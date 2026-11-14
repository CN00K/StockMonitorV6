import Foundation

public struct EncryptedSQLitePortableBackup: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let formatIdentifier = "StockMonitorV6.SQLitePortableBackup"

    public let format: String
    public let version: Int
    public let envelope: BackupEnvelope

    public init(format: String = EncryptedSQLitePortableBackup.formatIdentifier,
                version: Int = EncryptedSQLitePortableBackup.currentVersion,
                envelope: BackupEnvelope) {
        self.format = format
        self.version = version
        self.envelope = envelope
    }
}

public enum SQLitePortableBackupServiceError: Error, LocalizedError, Equatable, Sendable {
    case malformedFile
    case wrongFormat
    case unsupportedVersion(Int)
    case fileTooLarge
    case payloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .malformedFile: return "Encrypted SQLite backup file is malformed"
        case .wrongFormat: return "File is not a Stock Monitor SQLite backup"
        case .unsupportedVersion(let version): return "SQLite backup version is unsupported: \(version)"
        case .fileTooLarge: return "Encrypted SQLite backup exceeds the size limit"
        case .payloadTooLarge: return "Decrypted SQLite backup payload exceeds the size limit"
        }
    }
}

/// Local encrypted portability service. The caller supplies a 32-byte key from
/// a user-controlled secure boundary; this service never persists or derives it.
public struct SQLitePortableBackupService: Sendable {
    public static let defaultMaximumFileBytes = 32 * 1_024 * 1_024

    private let store: SQLiteMonitorStore
    private let cipher: any BackupCipher
    private let maximumFileBytes: Int
    private let maximumPayloadBytes: Int

    public init(store: SQLiteMonitorStore, cipher: any BackupCipher = AuthenticatedBackupCipher(),
                maximumFileBytes: Int = Self.defaultMaximumFileBytes,
                maximumPayloadBytes: Int = Self.defaultMaximumFileBytes) {
        self.store = store
        self.cipher = cipher
        self.maximumFileBytes = max(1_024, maximumFileBytes)
        self.maximumPayloadBytes = max(1_024, maximumPayloadBytes)
    }

    public func export(using key: Data, at date: Date = Date()) async throws -> Data {
        try await store.open()
        let snapshot = try await store.exportPortableBackupSnapshot(exportedAt: date)
        try snapshot.validate()
        let plaintext = try Self.encoder.encode(snapshot)
        guard plaintext.count <= maximumPayloadBytes else { throw SQLitePortableBackupServiceError.payloadTooLarge }
        let envelope = try cipher.encrypt(plaintext, using: key)
        guard envelope.version == BackupEnvelope.currentVersion else {
            throw BackupSecurityError.unsupportedVersion(envelope.version)
        }
        let file = EncryptedSQLitePortableBackup(envelope: envelope)
        let encoded = try Self.encoder.encode(file)
        guard encoded.count <= maximumFileBytes else { throw SQLitePortableBackupServiceError.fileTooLarge }
        return encoded
    }

    /// Validates and decrypts completely before invoking SQLite's atomic import.
    public func restore(_ data: Data, using key: Data) async throws {
        guard data.count <= maximumFileBytes else { throw SQLitePortableBackupServiceError.fileTooLarge }
        let file: EncryptedSQLitePortableBackup
        do { file = try Self.decoder.decode(EncryptedSQLitePortableBackup.self, from: data) }
        catch { throw SQLitePortableBackupServiceError.malformedFile }
        guard file.format == EncryptedSQLitePortableBackup.formatIdentifier else {
            throw SQLitePortableBackupServiceError.wrongFormat
        }
        guard file.version == EncryptedSQLitePortableBackup.currentVersion else {
            throw SQLitePortableBackupServiceError.unsupportedVersion(file.version)
        }
        let plaintext = try cipher.decrypt(file.envelope, using: key)
        guard plaintext.count <= maximumPayloadBytes else { throw SQLitePortableBackupServiceError.payloadTooLarge }
        let snapshot: SQLitePortableBackupSnapshot
        do { snapshot = try Self.decoder.decode(SQLitePortableBackupSnapshot.self, from: plaintext) }
        catch { throw SQLitePortableBackupServiceError.malformedFile }
        try snapshot.validate()
        try await store.open()
        try await store.importPortableBackupSnapshot(snapshot)
    }

    private static var encoder: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }

    private static var decoder: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}

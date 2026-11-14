import Foundation

/// Portable monitoring configuration and selected current working state. Raw-response
/// archive, session usage ledger, credentials and API keys are intentionally not
/// represented and do not migrate with this snapshot.
public struct PortableBackupSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public let version: Int
    public let exportedAt: Date
    public let watchCodes: [String]
    public let watchRules: [WatchRule]
    public let holdings: [Holding]
    public let signals: [AlertSignal]
    public let quotes: [Quote]
    public let indexQuotes: [Quote]
    public let events: [MarketEvent]
    public let settings: PortableBackupSettings
    /// Nil means legacy snapshots. An omission reason is explicit; it is never inferred.
    public let history: PortableBackupHistory?

    /// Caller-neutral names for the two persisted collections.
    public var watchlist: [String] { watchCodes }
    public var positions: [Holding] { holdings }

    public init(version: Int = PortableBackupSnapshot.currentVersion,
                exportedAt: Date = Date(), watchCodes: [String],
                watchRules: [WatchRule] = [], holdings: [Holding] = [],
                signals: [AlertSignal] = [], quotes: [Quote] = [],
                indexQuotes: [Quote] = [], events: [MarketEvent] = [],
                settings: PortableBackupSettings = PortableBackupSettings(),
                history: PortableBackupHistory? = nil) {
        self.version = version
        self.exportedAt = exportedAt
        self.watchCodes = watchCodes
        self.watchRules = watchRules
        self.holdings = holdings
        self.signals = signals
        self.quotes = quotes
        self.indexQuotes = indexQuotes
        self.events = events
        self.settings = settings
        self.history = history
    }

    /// Validates invariants which Codable alone cannot express.
    public func validate() throws {
        guard version == Self.currentVersion else { throw PortableBackupCodecError.unsupportedVersion(version) }
        guard exportedAt.timeIntervalSince1970.isFinite else { throw PortableBackupCodecError.invalidSnapshot("exportedAt") }
        guard uniqueNonEmpty(watchCodes) else { throw PortableBackupCodecError.invalidSnapshot("watchCodes") }
        guard uniqueNonEmpty(watchRules.map(\.id)) else { throw PortableBackupCodecError.invalidSnapshot("watchRules") }
        guard watchRules.allSatisfy({ watchCodes.contains($0.code) }) else {
            throw PortableBackupCodecError.invalidSnapshot("watchRules.code")
        }
        guard uniqueNonEmpty(holdings.map(\.code)) else { throw PortableBackupCodecError.invalidSnapshot("holdings") }
        guard uniqueNonEmpty(signals.map { $0.id.uuidString }) else { throw PortableBackupCodecError.invalidSnapshot("signals") }
        guard uniqueNonEmpty(events.map(\.id)) else { throw PortableBackupCodecError.invalidSnapshot("events") }
        guard uniqueNonEmpty(settings.ruleFamilySettings.map(\.id)) else {
            throw PortableBackupCodecError.invalidSnapshot("settings.ruleFamilySettings")
        }
        guard quotes.allSatisfy(Self.validQuote), indexQuotes.allSatisfy(Self.validQuote) else {
            throw PortableBackupCodecError.invalidSnapshot("quotes")
        }
        guard holdings.allSatisfy({ !$0.code.isEmpty && $0.shares >= 0 && $0.averageCost.isFinite && $0.averageCost >= 0 }) else {
            throw PortableBackupCodecError.invalidSnapshot("holdings.values")
        }
        if let history {
            if let reason = history.omissionReason {
                guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                      history.minuteBars.isEmpty, history.dailyBars.isEmpty else {
                    throw PortableBackupCodecError.invalidSnapshot("history.omissionReason")
                }
            } else {
                guard history.minuteBars.allSatisfy(Self.validMinuteBar),
                      history.dailyBars.allSatisfy(Self.validDailyBar) else {
                    throw PortableBackupCodecError.invalidSnapshot("history.values")
                }
            }
        }
    }

    private func uniqueNonEmpty(_ values: [String]) -> Bool {
        values.allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && Set(values).count == values.count
    }

    private static func validQuote(_ quote: Quote) -> Bool {
        !quote.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        quote.price.isFinite && quote.previousClose.isFinite && quote.open.isFinite &&
        quote.high.isFinite && quote.low.isFinite && (quote.amount.map { $0.isFinite } ?? true)
    }

    private static func validMinuteBar(_ bar: MinuteBar) -> Bool {
        !bar.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        bar.timestamp.timeIntervalSince1970.isFinite && bar.fetchedAt.timeIntervalSince1970.isFinite &&
        [bar.open, bar.close, bar.high, bar.low].allSatisfy(\.isFinite) &&
        (bar.amount.map { $0.isFinite } ?? true) && (bar.previousClose.map { $0.isFinite } ?? true)
    }

    private static func validDailyBar(_ bar: DailyBar) -> Bool {
        bar.code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil &&
        bar.tradeDate.timeIntervalSince1970.isFinite && bar.fetchedAt.timeIntervalSince1970.isFinite &&
        [bar.open, bar.high, bar.low, bar.close].allSatisfy(\.isFinite) &&
        (bar.amount.map { $0.isFinite } ?? true) && (bar.turnoverRate.map { $0.isFinite } ?? true)
    }
}

/// Historical bars are all-or-nothing in a portable snapshot. When caps prevent
/// inclusion, arrays remain empty and omissionReason states exactly why.
public struct PortableBackupHistory: Codable, Equatable, Sendable {
    public let minuteBars: [MinuteBar]
    public let dailyBars: [DailyBar]
    public let omissionReason: String?

    public init(minuteBars: [MinuteBar] = [], dailyBars: [DailyBar] = [], omissionReason: String? = nil) {
        self.minuteBars = minuteBars
        self.dailyBars = dailyBars
        self.omissionReason = omissionReason
    }
}

/// Settings and evaluator checkpoint kept with the portable snapshot.
public struct PortableBackupSettings: Codable, Equatable, Sendable {
    public let ruleFamilySettings: [RuleFamilySettings]
    public let ruleCheckpoint: RuleFamilyCheckpoint
    public let lastQuoteTime: Date?
    public let lastQuoteTimeByCode: [String: Date]
    public let lastMinuteTimestampByCode: [String: Date]

    public init(ruleFamilySettings: [RuleFamilySettings] = [],
                ruleCheckpoint: RuleFamilyCheckpoint = RuleFamilyCheckpoint(),
                lastQuoteTime: Date? = nil,
                lastQuoteTimeByCode: [String: Date] = [:],
                lastMinuteTimestampByCode: [String: Date] = [:]) {
        self.ruleFamilySettings = ruleFamilySettings
        self.ruleCheckpoint = ruleCheckpoint
        self.lastQuoteTime = lastQuoteTime
        self.lastQuoteTimeByCode = lastQuoteTimeByCode
        self.lastMinuteTimestampByCode = lastMinuteTimestampByCode
    }
}

/// Stable JSON representation of an encrypted portable backup.
public struct PortableBackupExport: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let envelope: BackupEnvelope

    public init(version: Int = PortableBackupExport.currentVersion, envelope: BackupEnvelope) {
        self.version = version
        self.envelope = envelope
    }
}

public enum PortableBackupCodecError: Error, Equatable, Sendable, LocalizedError {
    case malformed
    case unsupportedVersion(Int)
    case invalidSnapshot(String)
    case encryptionFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .malformed: return "Portable backup representation is malformed"
        case .unsupportedVersion(let version): return "Portable backup version is unsupported: \(version)"
        case .invalidSnapshot(let field): return "Portable backup snapshot is invalid: \(field)"
        case .encryptionFailed: return "Portable backup encryption failed"
        case .decryptionFailed: return "Portable backup decryption failed"
        }
    }
}

/// Functional-core codec. Persistence, storage, key retrieval, and caller wiring
/// remain outside this type; only the existing authenticated BackupCipher is injected.
public struct PortableBackupCodec: Sendable {
    private let cipher: any BackupCipher

    public init(cipher: any BackupCipher) {
        self.cipher = cipher
    }

    public func exportRepresentation(_ snapshot: PortableBackupSnapshot, using key: Data) throws -> PortableBackupExport {
        try snapshot.validate()
        let plaintext: Data
        do { plaintext = try Self.encoder.encode(snapshot) } catch { throw PortableBackupCodecError.malformed }
        let envelope: BackupEnvelope
        do { envelope = try cipher.encrypt(plaintext, using: key) } catch { throw PortableBackupCodecError.encryptionFailed }
        guard envelope.version == BackupEnvelope.currentVersion else {
            throw PortableBackupCodecError.unsupportedVersion(envelope.version)
        }
        return PortableBackupExport(envelope: envelope)
    }

    public func export(_ snapshot: PortableBackupSnapshot, using key: Data) throws -> Data {
        let representation = try exportRepresentation(snapshot, using: key)
        do { return try Self.encoder.encode(representation) } catch { throw PortableBackupCodecError.malformed }
    }

    public func importRepresentation(_ representation: PortableBackupExport, using key: Data) throws -> PortableBackupSnapshot {
        guard representation.version == PortableBackupExport.currentVersion,
              representation.envelope.version == BackupEnvelope.currentVersion else {
            let version = representation.version == PortableBackupExport.currentVersion
                ? representation.envelope.version : representation.version
            throw PortableBackupCodecError.unsupportedVersion(version)
        }
        let plaintext: Data
        do { plaintext = try cipher.decrypt(representation.envelope, using: key) } catch { throw PortableBackupCodecError.decryptionFailed }
        let snapshot: PortableBackupSnapshot
        do { snapshot = try Self.decoder.decode(PortableBackupSnapshot.self, from: plaintext) } catch {
            throw PortableBackupCodecError.malformed
        }
        try snapshot.validate()
        return snapshot
    }

    public func `import`(_ data: Data, using key: Data) throws -> PortableBackupSnapshot {
        let representation: PortableBackupExport
        do { representation = try Self.decoder.decode(PortableBackupExport.self, from: data) } catch {
            throw PortableBackupCodecError.malformed
        }
        return try importRepresentation(representation, using: key)
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

import Foundation

/// SQLite-specific metadata that complements PortableBackupSnapshot.
/// PortableBackupSnapshot intentionally contains only the portable signal payload;
/// this map preserves the database-only read state without changing that codec's
/// stable wire format. Missing entries mean unread.
public struct SQLitePortableBackupSnapshot: Codable, Equatable, Sendable {
    public let snapshot: PortableBackupSnapshot
    public let signalReadAt: [UUID: Date]

    public var version: Int { snapshot.version }
    public var exportedAt: Date { snapshot.exportedAt }
    public var watchCodes: [String] { snapshot.watchCodes }
    public var watchRules: [WatchRule] { snapshot.watchRules }
    public var holdings: [Holding] { snapshot.holdings }
    public var signals: [AlertSignal] { snapshot.signals }
    public var quotes: [Quote] { snapshot.quotes }
    public var indexQuotes: [Quote] { snapshot.indexQuotes }
    public var events: [MarketEvent] { snapshot.events }
    public var settings: PortableBackupSettings { snapshot.settings }

    public init(snapshot: PortableBackupSnapshot, signalReadAt: [UUID: Date] = [:]) {
        self.snapshot = snapshot
        self.signalReadAt = signalReadAt
    }

    public func validate() throws {
        try snapshot.validate()
        let signalIDs = Set(snapshot.signals.map(\.id))
        guard signalReadAt.keys.allSatisfy({ signalIDs.contains($0) }) else {
            throw PortableBackupCodecError.invalidSnapshot("signalReadAt")
        }
        guard signalReadAt.values.allSatisfy({ $0.timeIntervalSince1970.isFinite }) else {
            throw PortableBackupCodecError.invalidSnapshot("signalReadAt.date")
        }
    }
}

import Foundation

public enum MarketEventKind: String, Codable, Sendable, Equatable {
    case news
    case announcement
    case dragonTiger
}

public enum EventImpactScope: String, Codable, Sendable, Equatable {
    case market
    case sector
    case stock
    case unknown
}

/// Normalized, provenance-preserving event stored only in the local SQLite database.
public struct MarketEvent: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: MarketEventKind
    public let sourceID: String
    public let sourceItemID: String?
    public let title: String
    public let body: String?
    public let url: String?
    public let publishedAt: Date?
    public let latestPublishedAt: Date?
    public let fetchedAt: Date
    public let providerTimestampVerified: Bool
    public let priority: Int
    public let impactScope: EventImpactScope
    public let sectors: [String]
    public let stockCodes: [String]
    public let duplicateCount: Int
    public let corroboratingSources: [String]

    public init(id: String? = nil, kind: MarketEventKind = .news, sourceID: String,
                sourceItemID: String? = nil, title: String, body: String? = nil,
                url: String? = nil, publishedAt: Date? = nil, latestPublishedAt: Date? = nil,
                fetchedAt: Date = Date(), providerTimestampVerified: Bool = false, priority: Int = 3,
                impactScope: EventImpactScope = .unknown, sectors: [String] = [],
                stockCodes: [String] = [], duplicateCount: Int = 1,
                corroboratingSources: [String] = []) {
        self.kind = kind
        self.sourceID = sourceID
        self.sourceItemID = sourceItemID
        self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.body = body?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.url = url?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.publishedAt = publishedAt
        self.latestPublishedAt = latestPublishedAt ?? publishedAt
        self.fetchedAt = fetchedAt
        self.providerTimestampVerified = providerTimestampVerified && publishedAt != nil
        self.priority = min(5, max(1, priority))
        self.impactScope = impactScope
        self.sectors = Array(Set(sectors.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        self.stockCodes = Array(Set(stockCodes.filter { $0.range(of: "^[0-9]{6}$", options: .regularExpression) != nil })).sorted()
        self.duplicateCount = max(1, duplicateCount)
        self.corroboratingSources = Array(Set(corroboratingSources + [sourceID])).sorted()
        self.id = id ?? Self.stableID(sourceID: sourceID, sourceItemID: sourceItemID,
                                      url: url, title: self.title, publishedAt: publishedAt)
    }

    public var simHash: UInt64 { SimHash.fingerprint(title) }

    public func merging(_ other: MarketEvent) -> MarketEvent {
        let preferred = other.priority > priority ? other : self
        let mergedSectors = Array(Set(sectors + other.sectors)).sorted()
        let mergedCodes = Array(Set(stockCodes + other.stockCodes)).sorted()
        let mergedSources = Array(Set(corroboratingSources + other.corroboratingSources + [sourceID, other.sourceID])).sorted()
        let mergedScope: EventImpactScope = {
            if impactScope == .market || other.impactScope == .market { return .market }
            if !mergedSectors.isEmpty { return .sector }
            if !mergedCodes.isEmpty { return .stock }
            return preferred.impactScope
        }()
        let earliest = [publishedAt, other.publishedAt].compactMap { $0 }.min()
        let latest = [latestPublishedAt, other.latestPublishedAt, publishedAt, other.publishedAt]
            .compactMap { $0 }.max()
        return MarketEvent(id: preferred.id, kind: preferred.kind, sourceID: preferred.sourceID,
            sourceItemID: preferred.sourceItemID, title: preferred.title,
            body: preferred.body ?? other.body ?? body, url: preferred.url ?? other.url ?? url,
            publishedAt: earliest, latestPublishedAt: latest,
            fetchedAt: max(fetchedAt, other.fetchedAt),
            providerTimestampVerified: providerTimestampVerified || other.providerTimestampVerified,
            priority: max(priority, other.priority), impactScope: mergedScope,
            sectors: mergedSectors, stockCodes: mergedCodes,
            duplicateCount: duplicateCount + other.duplicateCount,
            corroboratingSources: mergedSources)
    }

    public func withEnrichment(sectors: [String], stockCodes: [String], impactScope: EventImpactScope) -> MarketEvent {
        MarketEvent(id: id, kind: kind, sourceID: sourceID, sourceItemID: sourceItemID,
            title: title, body: body, url: url, publishedAt: publishedAt,
            latestPublishedAt: latestPublishedAt, fetchedAt: fetchedAt,
            providerTimestampVerified: providerTimestampVerified, priority: priority,
            impactScope: impactScope, sectors: sectors, stockCodes: stockCodes,
            duplicateCount: duplicateCount, corroboratingSources: corroboratingSources)
    }

    public func withPriority(_ value: Int) -> MarketEvent {
        MarketEvent(id: id, kind: kind, sourceID: sourceID, sourceItemID: sourceItemID,
            title: title, body: body, url: url, publishedAt: publishedAt,
            latestPublishedAt: latestPublishedAt, fetchedAt: fetchedAt,
            providerTimestampVerified: providerTimestampVerified, priority: value,
            impactScope: impactScope, sectors: sectors, stockCodes: stockCodes,
            duplicateCount: duplicateCount, corroboratingSources: corroboratingSources)
    }

    private static func stableID(sourceID: String, sourceItemID: String?, url: String?,
                                 title: String, publishedAt: Date?) -> String {
        let identity = sourceItemID ?? url ?? "\(title.lowercased())|\(publishedAt.map { Int($0.timeIntervalSince1970 / 86_400) } ?? 0)"
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in "\(sourceID)|\(identity)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%@-%016llx", sourceID, hash)
    }
}

public struct EventSourceStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sourceID }
    public let sourceID: String
    public let fetchedAt: Date
    public let latestPublishedAt: Date?
    public let requestedCount: Int
    public let returnedCount: Int
    public let requestCount: Int
    public let successfulRequestCount: Int
    public let candidateRecordCount: Int
    public let validRecordCount: Int
    public let error: String?
    public let note: String?

    public init(sourceID: String, fetchedAt: Date = Date(), latestPublishedAt: Date? = nil,
                requestedCount: Int, returnedCount: Int, requestCount: Int,
                successfulRequestCount: Int? = nil, candidateRecordCount: Int = 0,
                validRecordCount: Int = 0, error: String? = nil, note: String? = nil) {
        self.sourceID = sourceID
        self.fetchedAt = fetchedAt
        self.latestPublishedAt = latestPublishedAt
        self.requestedCount = requestedCount
        self.returnedCount = returnedCount
        self.requestCount = max(0, requestCount)
        self.successfulRequestCount = min(self.requestCount, max(0, successfulRequestCount ?? (error == nil ? requestCount : 0)))
        self.candidateRecordCount = max(0, candidateRecordCount)
        self.validRecordCount = min(self.candidateRecordCount, max(0, validRecordCount))
        self.error = error
        self.note = note
    }

    public func freshness(at now: Date = Date(), staleAfter: TimeInterval = 24 * 60 * 60) -> SourceFreshness {
        if error != nil { return .failed }
        guard let latestPublishedAt else { return .unknown }
        return max(0, now.timeIntervalSince(latestPublishedAt)) <= staleAfter ? .fresh : .stale
    }
}

public struct EventFetchBatch: Sendable {
    public let events: [MarketEvent]
    public let status: EventSourceStatus
    public let rawResponses: [RawEventResponse]

    public init(events: [MarketEvent], status: EventSourceStatus,
                rawResponses: [RawEventResponse] = []) {
        self.events = events
        self.status = status
        self.rawResponses = rawResponses
    }
}

/// All event-source requests are initiated by a foreground user action; no background task is created.
public protocol MarketEventSource: Sendable {
    var identifier: String { get }
    func fetch(since: Date, limit: Int) async -> EventFetchBatch
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

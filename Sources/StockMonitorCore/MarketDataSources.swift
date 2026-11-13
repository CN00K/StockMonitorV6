import Foundation

public enum SourceFreshness: String, Codable, Sendable {
    case fresh, stale, unknown, failed
}

public struct SourceStatus: Codable, Sendable, Equatable, Identifiable {
    public var id: String { sourceID }
    public let sourceID: String
    public let fetchedAt: Date
    public let providerTimestamp: Date?
    public let requestedCount: Int
    public let returnedCount: Int
    public let requestCount: Int
    public let error: String?
    public let note: String?

    public init(sourceID: String, fetchedAt: Date, providerTimestamp: Date? = nil,
                requestedCount: Int, returnedCount: Int, requestCount: Int,
                error: String? = nil, note: String? = nil) {
        self.sourceID = sourceID
        self.fetchedAt = fetchedAt
        self.providerTimestamp = providerTimestamp
        self.requestedCount = requestedCount
        self.returnedCount = returnedCount
        self.requestCount = requestCount
        self.error = error
        self.note = note
    }

    public func freshness(at now: Date = Date(), staleAfter: TimeInterval = 120) -> SourceFreshness {
        if error != nil { return .failed }
        guard let providerTimestamp else { return .unknown }
        return abs(now.timeIntervalSince(providerTimestamp)) <= staleAfter ? .fresh : .stale
    }
}

public struct MarketIndex: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }
    public let code: String
    public let name: String
    public let eastmoneySecurityID: String
    public let sinaSymbol: String
    public let tencentSymbol: String

    public init(code: String, name: String, eastmoneySecurityID: String,
                sinaSymbol: String, tencentSymbol: String) {
        self.code = code
        self.name = name
        self.eastmoneySecurityID = eastmoneySecurityID
        self.sinaSymbol = sinaSymbol
        self.tencentSymbol = tencentSymbol
    }

    public static let core: [MarketIndex] = [
        .init(code: "000001", name: "上证指数", eastmoneySecurityID: "1.000001", sinaSymbol: "sh000001", tencentSymbol: "sh000001"),
        .init(code: "399001", name: "深证成指", eastmoneySecurityID: "0.399001", sinaSymbol: "sz399001", tencentSymbol: "sz399001"),
        .init(code: "399006", name: "创业板指", eastmoneySecurityID: "0.399006", sinaSymbol: "sz399006", tencentSymbol: "sz399006")
    ]
}

public struct ProviderQuoteBatch: Sendable {
    public let quotes: [Quote]
    public let indexQuotes: [Quote]
    public let status: SourceStatus

    public init(quotes: [Quote], indexQuotes: [Quote], status: SourceStatus) {
        self.quotes = quotes
        self.indexQuotes = indexQuotes
        self.status = status
    }
}

public struct MarketDataBatch: Sendable {
    public let quotes: [Quote]
    public let indexQuotes: [Quote]
    public let sourceStatuses: [SourceStatus]
    public let missingCodes: [String]
    public let missingIndexCodes: [String]

    public init(quotes: [Quote], indexQuotes: [Quote], sourceStatuses: [SourceStatus],
                missingCodes: [String] = [], missingIndexCodes: [String] = []) {
        self.quotes = quotes
        self.indexQuotes = indexQuotes
        self.sourceStatuses = sourceStatuses
        self.missingCodes = missingCodes
        self.missingIndexCodes = missingIndexCodes
    }
}

public protocol MarketQuoteSource: Sendable {
    var identifier: String { get }
    func fetchMarketData(codes: [String], indices: [MarketIndex]) async throws -> ProviderQuoteBatch
}

public protocol MarketDataProviding: Sendable {
    func fetch(codes: [String], indices: [MarketIndex]) async -> MarketDataBatch
}

public struct MinuteBar: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(code):\(timestamp.timeIntervalSince1970)" }
    public let code: String
    public let name: String
    public let timestamp: Date
    public let open: Double
    public let close: Double
    public let high: Double
    public let low: Double
    public let volume: Int64
    public let amount: Double?
    public let previousClose: Double?
    public let sourceID: String
    public let fetchedAt: Date

    public init(code: String, name: String, timestamp: Date, open: Double, close: Double,
                high: Double, low: Double, volume: Int64, amount: Double?, previousClose: Double?,
                sourceID: String, fetchedAt: Date) {
        self.code = code
        self.name = name
        self.timestamp = timestamp
        self.open = open
        self.close = close
        self.high = high
        self.low = low
        self.volume = volume
        self.amount = amount
        self.previousClose = previousClose
        self.sourceID = sourceID
        self.fetchedAt = fetchedAt
    }
}

public struct ReconcileReport: Codable, Sendable, Equatable {
    public let sourceID: String
    public let requestedCodes: [String]
    public let reconciledCodes: [String]
    public let skippedCodes: [String]
    public let barCount: Int
    public let earliestBar: Date?
    public let latestBar: Date?
    public let warnings: [String]
    public let requestCount: Int

    public init(sourceID: String, requestedCodes: [String], reconciledCodes: [String],
                skippedCodes: [String], barCount: Int, earliestBar: Date?, latestBar: Date?,
                warnings: [String], requestCount: Int) {
        self.sourceID = sourceID
        self.requestedCodes = requestedCodes
        self.reconciledCodes = reconciledCodes
        self.skippedCodes = skippedCodes
        self.barCount = barCount
        self.earliestBar = earliestBar
        self.latestBar = latestBar
        self.warnings = warnings
        self.requestCount = requestCount
    }
}

public struct ReconcileResult: Sendable {
    public let bars: [MinuteBar]
    public let report: ReconcileReport
    public let status: SourceStatus

    public init(bars: [MinuteBar], report: ReconcileReport, status: SourceStatus) {
        self.bars = bars
        self.report = report
        self.status = status
    }
}

public protocol HistoricalReconcileSource: Sendable {
    var identifier: String { get }
    func reconcile(codes: [String], afterByCode: [String: Date]) async -> ReconcileResult
}

public struct HostRequestPolicy: Sendable, Equatable {
    public let requestsPerSecond: Int
    public let maximumPerSession: Int?

    public init(requestsPerSecond: Int, maximumPerSession: Int? = nil) {
        self.requestsPerSecond = max(1, requestsPerSecond)
        self.maximumPerSession = maximumPerSession.map { max(1, $0) }
    }
}

public enum RequestBudgetError: Error, LocalizedError, Equatable {
    case sessionLimitExceeded(host: String, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .sessionLimitExceeded(let host, let limit):
            return "Request budget exhausted for \(host) (session cap \(limit))"
        }
    }
}

/// Shared host-level pacing with optional per-foreground-session caps.
public actor RequestBudget {
    private let policies: [String: HostRequestPolicy]
    private var recentRequests: [String: [Date]] = [:]
    private var sessionCounts: [String: Int] = [:]

    public init(policies: [String: HostRequestPolicy]) { self.policies = policies }

    public static func standard() -> RequestBudget {
        RequestBudget(policies: [
            "hq.sinajs.cn": .init(requestsPerSecond: 2, maximumPerSession: 2_000),
            "push2.eastmoney.com": .init(requestsPerSecond: 4, maximumPerSession: 2_000),
            "push2his.eastmoney.com": .init(requestsPerSecond: 4, maximumPerSession: 50),
            "qt.gtimg.cn": .init(requestsPerSecond: 2, maximumPerSession: 2_000),
            "www.cls.cn": .init(requestsPerSecond: 1, maximumPerSession: 20),
            "newsapi.eastmoney.com": .init(requestsPerSecond: 1, maximumPerSession: 20),
            "newsinfo.eastmoney.com": .init(requestsPerSecond: 1, maximumPerSession: 50),
            "cache.thepaper.cn": .init(requestsPerSecond: 1, maximumPerSession: 20),
            "sousuo.www.gov.cn": .init(requestsPerSecond: 1, maximumPerSession: 10),
            "www.cninfo.com.cn": .init(requestsPerSecond: 1, maximumPerSession: 24),
            "datacenter-web.eastmoney.com": .init(requestsPerSecond: 1, maximumPerSession: 10)
        ])
    }

    public func beginSession() {
        recentRequests.removeAll(keepingCapacity: true)
        sessionCounts.removeAll(keepingCapacity: true)
    }

    public func count(for host: String) -> Int { sessionCounts[host, default: 0] }

    public func acquire(host: String) async throws {
        let policy = policies[host] ?? HostRequestPolicy(requestsPerSecond: 1)
        while true {
            try Task.checkCancellation()
            let now = Date()
            if let cap = policy.maximumPerSession, sessionCounts[host, default: 0] >= cap {
                throw RequestBudgetError.sessionLimitExceeded(host: host, limit: cap)
            }
            let active = (recentRequests[host] ?? []).filter { now.timeIntervalSince($0) < 1 }
            if active.count < policy.requestsPerSecond {
                recentRequests[host] = active + [now]
                sessionCounts[host, default: 0] += 1
                return
            }
            let oldest = active.min() ?? now
            let wait = max(0.01, 1 - now.timeIntervalSince(oldest))
            try await Task.sleep(for: .milliseconds(Int64(wait * 1_000)))
        }
    }
}

public enum QuoteRegistryError: Error, LocalizedError {
    case noUsableQuotes

    public var errorDescription: String? {
        switch self {
        case .noUsableQuotes: return "All configured quote sources returned no usable stock or index quotes"
        }
    }
}

/// Sequential failover; successful values are never silently overwritten by a later source.
public struct QuoteSourceRegistry: Sendable {
    private let sources: [any MarketQuoteSource]

    public init(sources: [any MarketQuoteSource]) { self.sources = sources }

    public func fetch(codes: [String], indices: [MarketIndex] = []) async -> MarketDataBatch {
        let requestedCodes = Array(Set(codes)).sorted()
        let requestedIndexCodes = Set(indices.map(\.code))
        var stockByCode: [String: Quote] = [:]
        var indexByCode: [String: Quote] = [:]
        var statuses: [SourceStatus] = []

        for source in sources {
            if Task.isCancelled { break }
            let missingCodes = requestedCodes.filter { stockByCode[$0] == nil }
            let missingIndices = indices.filter { indexByCode[$0.code] == nil }
            if missingCodes.isEmpty && missingIndices.isEmpty { break }
            do {
                let batch = try await source.fetchMarketData(codes: missingCodes, indices: missingIndices)
                statuses.append(batch.status)
                for quote in batch.quotes where quote.kind == .stock && missingCodes.contains(quote.code) && quote.price.isFinite && quote.price >= 0 {
                    stockByCode[quote.code] = quote
                }
                for quote in batch.indexQuotes where quote.kind == .index && missingIndices.contains(where: { $0.code == quote.code }) && quote.price.isFinite && quote.price >= 0 {
                    indexByCode[quote.code] = quote
                }
            } catch {
                statuses.append(SourceStatus(sourceID: source.identifier, fetchedAt: Date(),
                    requestedCount: missingCodes.count + missingIndices.count, returnedCount: 0,
                    requestCount: 1, error: error.localizedDescription,
                    note: "Provider request failed; earlier batches may not be counted; trying next configured source"))
                if Task.isCancelled { break }
            }
        }
        let missing = requestedCodes.filter { stockByCode[$0] == nil }
        let missingIndices = requestedIndexCodes.filter { indexByCode[$0] == nil }.sorted()
        return MarketDataBatch(quotes: requestedCodes.compactMap { stockByCode[$0] },
            indexQuotes: indices.compactMap { indexByCode[$0.code] }, sourceStatuses: statuses,
            missingCodes: missing, missingIndexCodes: missingIndices)
    }
}

extension QuoteSourceRegistry: MarketDataProviding {}

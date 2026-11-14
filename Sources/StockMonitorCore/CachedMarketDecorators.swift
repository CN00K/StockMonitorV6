import Foundation

public enum MarketCoverageCacheError: Error, LocalizedError, Sendable {
    case coolingDown

    public var errorDescription: String? {
        "Market-wide scan is cooling down after a recent attempt; no extra request was sent."
    }
}

/// Reduces full-universe scanning to one bounded attempt per refresh interval.
/// A cached result keeps its original fetchedAt timestamp so downstream code can
/// distinguish old coverage; requestCount is zero on cache hits.
public actor CachingMarketCoverageProvider: MarketCoverageProviding {
    private let upstream: any MarketCoverageProviding
    private let minimumRefreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private var lastAttemptAt: Date?
    private var cached: MarketCoverageSnapshot?

    public init(upstream: any MarketCoverageProviding, minimumRefreshInterval: TimeInterval = 15 * 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.upstream = upstream
        self.minimumRefreshInterval = max(60, minimumRefreshInterval)
        self.now = now
    }

    public func fetchCoverage() async throws -> MarketCoverageSnapshot {
        let reference = now()
        if let cached, let lastAttemptAt,
           reference.timeIntervalSince(lastAttemptAt) < minimumRefreshInterval {
            return Self.withCacheStatus(cached, note: "Cached market scan; source timestamp is preserved.")
        }
        if let lastAttemptAt, cached == nil,
           reference.timeIntervalSince(lastAttemptAt) < minimumRefreshInterval {
            throw MarketCoverageCacheError.coolingDown
        }
        lastAttemptAt = reference
        let fresh = try await upstream.fetchCoverage()
        cached = fresh
        return fresh
    }

    private static func withCacheStatus(_ value: MarketCoverageSnapshot, note: String) -> MarketCoverageSnapshot {
        let old = value.status
        let status = SourceStatus(sourceID: old.sourceID, fetchedAt: old.fetchedAt,
            providerTimestamp: old.providerTimestamp, requestedCount: old.requestedCount,
            returnedCount: old.returnedCount, requestCount: 0, error: old.error,
            note: [old.note, note].compactMap { $0 }.joined(separator: " "))
        return MarketCoverageSnapshot(summary: value.summary, topQuotes: value.topQuotes,
            sampleDistribution: value.sampleDistribution, status: status)
    }
}

/// Bounded round-robin minute-flow cache. Only fresh provider timestamps are
/// returned to the quote decorator; stale/missing values remain nil.
public actor CachingMoneyFlowProvider: MoneyFlowProviding {
    private let upstream: any MoneyFlowProviding
    private let maximumSymbols: Int
    private let minimumRefreshInterval: TimeInterval
    private let maximumAge: TimeInterval
    private let now: @Sendable () -> Date
    private var lastAttemptAt: Date?
    private var lastSelectedCode: String?
    private var cache: [String: MoneyFlowMinute] = [:]

    public init(upstream: any MoneyFlowProviding, maximumSymbols: Int = 2,
                minimumRefreshInterval: TimeInterval = 10 * 60,
                maximumAge: TimeInterval = 2 * 60,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.upstream = upstream
        self.maximumSymbols = min(50, max(1, maximumSymbols))
        self.minimumRefreshInterval = max(1, minimumRefreshInterval)
        self.maximumAge = max(30, maximumAge)
        self.now = now
    }

    public func fetch(codes: [String]) async -> MoneyFlowBatch {
        let requested = Array(Set(codes.filter(Self.isSixDigitCode))).sorted()
        guard !requested.isEmpty else {
            return MoneyFlowBatch(minutes: [], status: SourceStatus(sourceID: "eastmoney_fflow",
                fetchedAt: now(), requestedCount: 0, returnedCount: 0, requestCount: 0,
                note: "No supported stock codes were supplied."))
        }
        let reference = now()
        let stale = requested.filter { !Self.isFresh(cache[$0], at: reference, maximumAge: maximumAge) }
        let cooldownActive = lastAttemptAt.map { reference.timeIntervalSince($0) < minimumRefreshInterval } ?? false
        var upstreamBatch: MoneyFlowBatch?
        if !stale.isEmpty, !cooldownActive {
            let ordered = rotate(stale, after: lastSelectedCode)
            let selected = Array(ordered.prefix(maximumSymbols))
            if let last = selected.last { lastSelectedCode = last }
            lastAttemptAt = reference
            let fetched = await upstream.fetch(codes: selected)
            for minute in fetched.minutes where requested.contains(minute.code) {
                cache[minute.code] = minute
            }
            upstreamBatch = fetched
        }
        let freshRows = requested.compactMap { code -> MoneyFlowMinute? in
            guard let value = cache[code], Self.isFresh(value, at: reference, maximumAge: maximumAge) else { return nil }
            return value
        }
        let base = upstreamBatch?.status
        let note: String
        if let base {
            note = (base.note ?? "Minute-flow request completed.")
                + (stale.count > maximumSymbols ? " Only \(maximumSymbols) stale symbols were requested this cycle; selection rotates across the requested codes." : "")
        } else if stale.isEmpty {
            note = "All returned minute-flow rows are fresh in the local cache."
        } else if cooldownActive {
            note = "Minute-flow request is rate-limited locally; only fresh cached rows are returned."
        } else {
            note = "No fresh minute-flow values were available; unsupported values remain nil."
        }
        let status = SourceStatus(sourceID: base?.sourceID ?? "eastmoney_fflow",
            fetchedAt: base?.fetchedAt ?? reference,
            providerTimestamp: freshRows.map(\.timestamp).max() ?? base?.providerTimestamp,
            requestedCount: requested.count, returnedCount: freshRows.count,
            requestCount: base?.requestCount ?? 0, error: base?.error, note: note)
        return MoneyFlowBatch(minutes: freshRows, status: status)
    }

    private func rotate(_ values: [String], after code: String?) -> [String] {
        guard !values.isEmpty, let code, let index = values.firstIndex(of: code) else { return values }
        let next = (index + 1) % values.count
        return Array(values[next...]) + Array(values[..<next])
    }

    private static func isFresh(_ value: MoneyFlowMinute?, at reference: Date, maximumAge: TimeInterval) -> Bool {
        guard let value else { return false }
        let age = reference.timeIntervalSince(value.timestamp)
        return age >= -60 && age <= maximumAge
    }

    private static func isSixDigitCode(_ code: String) -> Bool {
        code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil
    }
}

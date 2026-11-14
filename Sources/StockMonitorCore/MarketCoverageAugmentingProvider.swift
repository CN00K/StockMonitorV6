import Foundation

/// Bounded, explicitly fetched market-wide context; unavailable limit counts stay nil.
public struct MarketCoverageSnapshot: Codable, Sendable, Equatable {
    public let summary: MarketScanSummary
    public let topQuotes: [EastmoneyScanQuote]
    public let sampleDistribution: MarketScanDistribution?
    public let status: SourceStatus

    public init(summary: MarketScanSummary, topQuotes: [EastmoneyScanQuote],
                sampleDistribution: MarketScanDistribution? = nil, status: SourceStatus) {
        self.summary = summary
        self.topQuotes = topQuotes
        self.sampleDistribution = sampleDistribution
        self.status = status
    }

    public init(result: EastmoneyMarketScanResult) {
        self.init(summary: result.summary, topQuotes: result.topByPercent,
            sampleDistribution: MarketScanDistribution.summarize(quotes: result.quotes), status: result.status)
    }
}

public protocol MarketCoverageProviding: Sendable {
    func fetchCoverage() async throws -> MarketCoverageSnapshot
}

extension EastmoneyMarketScanSource: MarketCoverageProviding {
    public func fetchCoverage() async throws -> MarketCoverageSnapshot {
        MarketCoverageSnapshot(result: try await fetchUniverse())
    }
}

/// Optional provider decorator. Without explicit injection, no market-wide scan is requested.
public struct MarketCoverageAugmentingProvider: MarketDataProviding {
    private let quotes: any MarketDataProviding
    private let coverage: any MarketCoverageProviding

    public init(quotes: any MarketDataProviding, coverage: any MarketCoverageProviding) {
        self.quotes = quotes
        self.coverage = coverage
    }

    public func fetch(codes: [String], indices: [MarketIndex]) async -> MarketDataBatch {
        let batch = await quotes.fetch(codes: codes, indices: indices)
        guard !Task.isCancelled else { return batch }
        do {
            let snapshot = try await coverage.fetchCoverage()
            return MarketDataBatch(quotes: batch.quotes, indexQuotes: batch.indexQuotes,
                sourceStatuses: batch.sourceStatuses + [snapshot.status],
                missingCodes: batch.missingCodes, missingIndexCodes: batch.missingIndexCodes,
                suspectCodes: batch.suspectCodes, marketCoverage: snapshot)
        } catch is CancellationError {
            return batch
        } catch {
            let status = SourceStatus(sourceID: "eastmoney.clist", fetchedAt: Date(),
                requestedCount: 0, returnedCount: 0, requestCount: 0,
                error: error.localizedDescription,
                note: "Optional bounded market scan failed; no breadth values were substituted.")
            return MarketDataBatch(quotes: batch.quotes, indexQuotes: batch.indexQuotes,
                sourceStatuses: batch.sourceStatuses + [status],
                missingCodes: batch.missingCodes, missingIndexCodes: batch.missingIndexCodes,
                suspectCodes: batch.suspectCodes)
        }
    }
}

import Foundation

/// Adds a local, day-scoped cache and usage ledger around ``OnDemandAnalyst``.
///
/// The API key is used only for the provider call and is never part of the cache
/// key or persisted data. Cache identity is delegated to ``AnalystResultCacheKey``.
public struct CachedOnDemandAnalyst: Sendable {
    private let analyst: OnDemandAnalyst
    private let store: SQLiteMonitorStore

    public init(store: SQLiteMonitorStore,
                analyst: OnDemandAnalyst = OnDemandAnalyst()) {
        self.store = store
        self.analyst = analyst
    }

    /// Returns a cached result when available, otherwise performs one complete
    /// on-demand analysis and persists the successful result.
    ///
    /// `at` is injectable for deterministic callers and tests; it controls the
    /// China trading-day cache partition and the cache expiry timestamp. The API
    /// key is deliberately not retained by this type.
    public func analyze(context: AnalystContext,
                        configuration: OnDemandAnalystConfiguration,
                        apiKey: String,
                        at date: Date = Date()) async throws -> StrategyResult {
        let key = AnalystResultCacheKey(stockCode: context.stock.code,
                                        endpoint: configuration.endpoint,
                                        modelID: configuration.modelID,
                                        context: context,
                                        at: date)

        if let cached = try await store.cachedAnalystResult(for: key, now: date) {
            return cached
        }

        // Do not write anything until the entire provider operation succeeds.
        let output = try await analyst.analyzeWithUsage(context: context,
                                                        configuration: configuration,
                                                        apiKey: apiKey)
        try await store.storeAnalystResult(output.result, for: key, storedAt: date)
        try await store.recordAnalystUsage(for: key, requestCount: output.usage.requestCount,
            promptTokenCount: output.usage.promptTokenCount,
            completionTokenCount: output.usage.completionTokenCount,
            totalTokenCount: output.usage.totalTokenCount)
        try await store.recordSessionActivity(ticks: 0, requests: output.usage.requestCount,
            promptTokens: output.usage.promptTokenCount,
            completionTokens: output.usage.completionTokenCount,
            totalTokens: output.usage.totalTokenCount)
        return output.result
    }
}

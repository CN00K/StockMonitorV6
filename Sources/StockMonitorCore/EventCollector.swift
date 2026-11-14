import Foundation

public struct EventCollectionReport: Sendable {
    public let sourceStatuses: [EventSourceStatus]
    public let receivedCount: Int
    public let storedCount: Int
    public let visibleCount: Int
    public let visibleEvents: [MarketEvent]
    public let storageError: String?

    public init(sourceStatuses: [EventSourceStatus], receivedCount: Int,
                storedCount: Int, visibleCount: Int = 0, visibleEvents: [MarketEvent] = [],
                storageError: String? = nil) {
        self.sourceStatuses = sourceStatuses
        self.receivedCount = receivedCount
        self.storedCount = storedCount
        self.visibleCount = visibleCount
        self.visibleEvents = visibleEvents
        self.storageError = storageError
    }
}

/// Coordinates only explicit refresh/export calls. It has no timer, background task, or owned server.
public actor EventCollector {
    private let store: any MonitorStore
    private let sources: [any MarketEventSource]
    private let processor: EventProcessor
    private let enricher: EventLLMEnricher?
    private let maximumPerSource: Int

    public init(store: any MonitorStore, sources: [any MarketEventSource],
                processor: EventProcessor, maximumPerSource: Int = 30,
                enricher: EventLLMEnricher? = nil) {
        self.store = store
        self.sources = sources
        self.processor = processor
        self.enricher = enricher
        self.maximumPerSource = max(1, min(100, maximumPerSource))
    }

    public func refresh(since: Date, stockCodes: [String] = [], limitPerSource: Int? = nil) async -> EventCollectionReport {
        let limit = max(1, min(maximumPerSource, limitPerSource ?? maximumPerSource))
        var statuses: [EventSourceStatus] = []
        var received: [MarketEvent] = []
        var rawResponses: [RawEventResponse] = []
        for source in sources {
            guard !Task.isCancelled else { break }
            let batch: EventFetchBatch
            if let stockAware = source as? any StockAwareMarketEventSource {
                batch = await stockAware.fetch(since: since, limit: limit, stockCodes: stockCodes)
            } else {
                batch = await source.fetch(since: since, limit: limit)
            }
            statuses.append(batch.status)
            received.append(contentsOf: batch.events)
            rawResponses.append(contentsOf: batch.rawResponses)
        }
        guard !Task.isCancelled else {
            return EventCollectionReport(sourceStatuses: statuses, receivedCount: received.count, storedCount: 0,
                storageError: "Refresh was cancelled before the local commit.")
        }
        let enrichment: EventLLMEnrichmentBatch
        do {
            if let enricher {
                enrichment = try await enricher.enrichWithUsage(received)
            } else {
                enrichment = EventLLMEnrichmentBatch(events: received, usage: AnalystUsageLedger(requestCount: 0))
            }
        } catch is CancellationError {
            return EventCollectionReport(sourceStatuses: statuses, receivedCount: received.count, storedCount: 0,
                storageError: "Refresh was cancelled before the local commit.")
        } catch {
            enrichment = EventLLMEnrichmentBatch(events: received, usage: AnalystUsageLedger(requestCount: 0))
        }
        let enriched = enrichment.events
        let sourceRequestCount = statuses.reduce(0) { $0 + max(0, $1.requestCount) }
        let llmUsage = enrichment.usage
        try? await store.recordSessionActivity(ticks: 0,
            requests: sourceRequestCount + llmUsage.requestCount,
            promptTokens: llmUsage.promptTokenCount,
            completionTokens: llmUsage.completionTokenCount,
            totalTokens: llmUsage.totalTokenCount)
        let processed = processor.processWithMetrics(enriched)
        let visible = processed.events
        let p1Statuses = statuses.filter { ["gov", "cninfo"].contains($0.sourceID.lowercased()) }
        let healthDay = Self.chinaCalendar().startOfDay(for: Date())
        let health = SourceHealthDelta(day: healthDay,
            p1Successes: p1Statuses.reduce(0) { $0 + $1.successfulRequestCount },
            p1Attempts: p1Statuses.reduce(0) { $0 + $1.requestCount },
            filterKept: statuses.reduce(0) { $0 + $1.validRecordCount },
            filterTotal: statuses.reduce(0) { $0 + $1.candidateRecordCount },
            ruleOrSkippedDecisions: visible.count)
        do {
            try await store.upsertEvents(enriched)
            try await store.recordEventRejections(processed.rejections)
            _ = try await store.archiveRawResponses(rawResponses)
            try await store.recordSourceHealth(health)
            return EventCollectionReport(sourceStatuses: statuses, receivedCount: received.count,
                storedCount: enriched.count, visibleCount: visible.count, visibleEvents: visible)
        } catch {
            return EventCollectionReport(sourceStatuses: statuses, receivedCount: received.count,
                storedCount: 0, visibleCount: visible.count, visibleEvents: visible,
                storageError: error.localizedDescription)
        }
    }

    public func events(on day: Date) async throws -> [MarketEvent] {
        let calendar = Self.chinaCalendar()
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return try await store.fetchEvents(from: start, to: end)
    }

    public func events(from start: Date, to end: Date) async throws -> [MarketEvent] {
        guard start <= end else { return [] }
        return try await store.fetchEvents(from: start, to: end)
    }

    public func dailySummary(on day: Date = Date(), generatedAt: Date = Date()) async throws -> DailyEventSummary {
        let records = try await events(on: day)
        return processor.summary(events: records, day: day, calendar: Self.chinaCalendar(), generatedAt: generatedAt)
    }

    public func exportFile(on day: Date = Date(), format: EventExportFormat) async throws -> URL {
        let records = try await events(on: day)
        let deduplicated = processor.process(records)
        return try EventExporter.writeTemporaryFile(events: deduplicated, format: format)
    }

    private static func chinaCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        return calendar
    }
}

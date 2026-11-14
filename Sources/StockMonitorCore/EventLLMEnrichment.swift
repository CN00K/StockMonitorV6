import Foundation

/// The only event data supplied to an enrichment client. API keys are deliberately
/// transient request data and are never retained by the core.
public struct EventLLMEnrichmentRequest: Sendable, Equatable {
    public let event: MarketEvent
    public let apiKey: String

    public init(event: MarketEvent, apiKey: String) {
        self.event = event
        self.apiKey = apiKey
    }
}

public struct EventLLMEnrichment: Sendable, Equatable {
    public let sectors: [String]
    public let stockCodes: [String]
    public let impactScope: EventImpactScope?
    public let priority: Int?
    public let promptTokenCount: Int?
    public let completionTokenCount: Int?
    public let totalTokenCount: Int?

    public init(sectors: [String] = [], stockCodes: [String] = [],
                impactScope: EventImpactScope? = nil, priority: Int? = nil,
                promptTokenCount: Int? = nil, completionTokenCount: Int? = nil,
                totalTokenCount: Int? = nil) {
        self.sectors = sectors
        self.stockCodes = stockCodes
        self.impactScope = impactScope
        self.priority = priority
        self.promptTokenCount = promptTokenCount.map { max(0, $0) }
        self.completionTokenCount = completionTokenCount.map { max(0, $0) }
        self.totalTokenCount = totalTokenCount.map { max(0, $0) }
    }
}

public struct EventLLMEnrichmentBatch: Sendable, Equatable {
    public let events: [MarketEvent]
    public let usage: AnalystUsageLedger

    public init(events: [MarketEvent], usage: AnalystUsageLedger) {
        self.events = events
        self.usage = usage
    }
}

/// Implementations may be backed by an application service, but the core ships
/// without one and never creates a network client itself.
public protocol EventLLMEnrichmentClient: Sendable {
    func enrich(_ request: EventLLMEnrichmentRequest) async throws -> EventLLMEnrichment
}

/// Key lookup is injected so the functional core never reads, stores, or logs credentials.
public protocol EventLLMAPIKeyProvider: Sendable {
    func apiKey() async -> String?
}

public enum EventLLMTier: String, Sendable, Equatable {
    case full
    case conditional
    case rulesOnly
}

public struct EventLLMEnrichmentConfig: Sendable {
    public let enabled: Bool
    public let tiers: [Int: EventLLMTier]
    public let conditionalRequiresMissingMetadata: Bool
    public let keyProvider: (any EventLLMAPIKeyProvider)?

    public init(enabled: Bool = false,
                tiers: [Int: EventLLMTier] = [5: .full, 4: .full, 3: .conditional,
                                               2: .rulesOnly, 1: .rulesOnly],
                conditionalRequiresMissingMetadata: Bool = true,
                keyProvider: (any EventLLMAPIKeyProvider)? = nil) {
        self.enabled = enabled
        self.tiers = tiers
        self.conditionalRequiresMissingMetadata = conditionalRequiresMissingMetadata
        self.keyProvider = keyProvider
    }

    public static let disabled = EventLLMEnrichmentConfig()

    public func tier(forPriority priority: Int) -> EventLLMTier {
        tiers[min(5, max(1, priority))] ?? .rulesOnly
    }

    public func shouldEnrich(event: MarketEvent, sourcePriority: (String) -> Int) -> Bool {
        guard enabled else { return false }
        let tier = tier(forPriority: sourcePriority(event.sourceID))
        switch tier {
        case .full: return true
        case .rulesOnly: return false
        case .conditional:
            return !conditionalRequiresMissingMetadata ||
                (event.sectors.isEmpty && event.stockCodes.isEmpty && event.impactScope == .unknown)
        }
    }

    public static func parseYAML(_ text: String, keyProvider: (any EventLLMAPIKeyProvider)? = nil) -> EventLLMEnrichmentConfig {
        var stack: [(indent: Int, key: String)] = []
        var values: [String: String] = [:]
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let colon = line.firstIndex(of: ":") else { continue }
            let indent = raw.prefix { $0 == " " }.count
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            while let last = stack.last, last.indent >= indent { stack.removeLast() }
            let path = (stack.map(\.key) + [key]).joined(separator: ".")
            if value.isEmpty {
                stack.append((indent, key))
            } else {
                values[path] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }
        let enabled = values["llm_enrichment.enabled"]?.lowercased() == "true"
        func tier(_ key: String, _ fallback: EventLLMTier) -> EventLLMTier {
            switch values["llm_enrichment.tiered_strategy.\(key)"]?.lowercased() {
            case "full": return .full
            case "conditional": return .conditional
            case "rules_only", "rulesonly": return .rulesOnly
            default: return fallback
            }
        }
        return EventLLMEnrichmentConfig(enabled: enabled,
            tiers: [5: tier("P1", .full), 4: tier("P2", .full), 3: tier("P3", .conditional),
                    2: tier("P4", .rulesOnly), 1: tier("P5", .rulesOnly)], keyProvider: keyProvider)
    }
}

public struct EventLLMEnricher: Sendable {
    private let client: (any EventLLMEnrichmentClient)?
    private let config: EventLLMEnrichmentConfig
    private let sourcePriority: [String: Int]

    public init(client: (any EventLLMEnrichmentClient)? = nil,
                config: EventLLMEnrichmentConfig = .disabled,
                sourcePriority: [String: Int] = CollectorEventPolicy.stockAgentDefaults.sourcePriority) {
        self.client = client
        self.config = config
        self.sourcePriority = Dictionary(uniqueKeysWithValues: sourcePriority.map { ($0.key.lowercased(), $0.value) })
    }

    public func enrich(_ events: [MarketEvent]) async throws -> [MarketEvent] {
        try await enrichWithUsage(events).events
    }

    public func enrichWithUsage(_ events: [MarketEvent]) async throws -> EventLLMEnrichmentBatch {
        guard let client, config.enabled, let keyProvider = config.keyProvider,
              let key = await keyProvider.apiKey(), !key.isEmpty else {
            return EventLLMEnrichmentBatch(events: events, usage: AnalystUsageLedger(requestCount: 0))
        }
        var result: [MarketEvent] = []
        result.reserveCapacity(events.count)
        var requestCount = 0
        var promptTokens: Int?
        var completionTokens: Int?
        var totalTokens: Int?
        for event in events {
            try Task.checkCancellation()
            guard config.shouldEnrich(event: event, sourcePriority: { sourcePriority[$0.lowercased()] ?? 3 }) else {
                result.append(event)
                continue
            }
            requestCount += 1
            do {
                let metadata = try await client.enrich(EventLLMEnrichmentRequest(event: event, apiKey: key))
                promptTokens = Self.add(promptTokens, metadata.promptTokenCount)
                completionTokens = Self.add(completionTokens, metadata.completionTokenCount)
                totalTokens = Self.add(totalTokens, metadata.totalTokenCount)
                let scope = metadata.impactScope ?? event.impactScope
                let enriched = event.withEnrichment(
                    sectors: event.sectors + metadata.sectors,
                    stockCodes: event.stockCodes + metadata.stockCodes,
                    impactScope: scope)
                    .withPriority(metadata.priority ?? event.priority)
                result.append(enriched)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                result.append(event)
            }
        }
        return EventLLMEnrichmentBatch(events: result, usage: AnalystUsageLedger(
            requestCount: requestCount, promptTokenCount: promptTokens,
            completionTokenCount: completionTokens, totalTokenCount: totalTokens))
    }

    private static func add(_ current: Int?, _ next: Int?) -> Int? {
        guard let next else { return current }
        let (sum, overflow) = (current ?? 0).addingReportingOverflow(next)
        return overflow ? Int.max : sum
    }
}

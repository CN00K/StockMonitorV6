import Foundation

public struct CollectorEventPolicy: Sendable, Equatable {
    public let filterEnabled: Bool
    public let titleSimilarityThreshold: Double
    public let lowPriorityNoSectorEnabled: Bool
    public let lowPriorityMax: Int
    public let lowValueIndividualEnabled: Bool
    public let lowValueMaxPriority: Int
    public let lowValueMinNewsCount: Int
    public let alwaysKeepMinPriority: Int
    public let alwaysKeepNewsCount: Int
    public let sourcePriority: [String: Int]

    public init(filterEnabled: Bool = true, titleSimilarityThreshold: Double = 0.85,
                lowPriorityNoSectorEnabled: Bool = true, lowPriorityMax: Int = 2,
                lowValueIndividualEnabled: Bool = true, lowValueMaxPriority: Int = 2,
                lowValueMinNewsCount: Int = 2, alwaysKeepMinPriority: Int = 3,
                alwaysKeepNewsCount: Int = 3, sourcePriority: [String: Int] = [:]) {
        self.filterEnabled = filterEnabled
        self.titleSimilarityThreshold = min(1, max(0, titleSimilarityThreshold))
        self.lowPriorityNoSectorEnabled = lowPriorityNoSectorEnabled
        self.lowPriorityMax = max(1, min(5, lowPriorityMax))
        self.lowValueIndividualEnabled = lowValueIndividualEnabled
        self.lowValueMaxPriority = max(1, min(5, lowValueMaxPriority))
        self.lowValueMinNewsCount = max(1, lowValueMinNewsCount)
        self.alwaysKeepMinPriority = max(1, min(5, alwaysKeepMinPriority))
        self.alwaysKeepNewsCount = max(1, alwaysKeepNewsCount)
        self.sourcePriority = sourcePriority.mapKeys { $0.lowercased() }
    }

    public static let stockAgentDefaults = CollectorEventPolicy(sourcePriority: [
        "gov": 5, "gov-cn-official-news-policy": 5, "cninfo": 5,
        "miit": 4, "miit_official_news": 4, "cls": 3, "eastmoney_lhb": 3,
        "eastmoney": 2, "eastmoney_news": 2, "thepaper": 2, "xueqiu": 1
    ])

    public func priority(for sourceID: String, fallback: Int = 3) -> Int {
        sourcePriority[sourceID.lowercased()] ?? fallback
    }

    public func keep(_ event: MarketEvent) -> Bool {
        guard filterEnabled else { return true }
        let highValue = event.priority >= alwaysKeepMinPriority || !event.sectors.isEmpty ||
            event.duplicateCount >= alwaysKeepNewsCount
        if highValue { return true }
        if lowPriorityNoSectorEnabled, event.priority <= lowPriorityMax, event.sectors.isEmpty { return false }
        if lowValueIndividualEnabled, event.priority <= lowValueMaxPriority,
           event.impactScope == .stock, event.duplicateCount < lowValueMinNewsCount { return false }
        return true
    }

    /// Parses only the stable scalar/list subset used by Resources/collector.yaml.
    public static func parseYAML(_ text: String) -> CollectorEventPolicy {
        var stack: [(indent: Int, key: String)] = []
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let indent = rawLine.prefix { $0 == " " }.count
            guard let colon = line.firstIndex(of: ":") else { continue }
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
        func int(_ path: String, _ fallback: Int) -> Int { Int(values[path] ?? "") ?? fallback }
        func double(_ path: String, _ fallback: Double) -> Double { Double(values[path] ?? "") ?? fallback }
        func bool(_ path: String, _ fallback: Bool) -> Bool {
            guard let raw = values[path]?.lowercased() else { return fallback }
            return raw == "true" ? true : raw == "false" ? false : fallback
        }
        var priorities: [String: Int] = [:]
        for rank in 1...5 {
            let path = "source_priority.P\(rank)"
            guard let raw = values[path], raw.hasPrefix("["), raw.hasSuffix("]") else { continue }
            let identifiers = raw.dropFirst().dropLast().split(separator: ",").map {
                String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \\\"'"))
            }
            for identifier in identifiers { priorities[identifier.lowercased()] = 6 - rank }
        }
        return CollectorEventPolicy(
            filterEnabled: bool("event_filter.enabled", true),
            titleSimilarityThreshold: double("title_similarity_threshold", 0.85),
            lowPriorityNoSectorEnabled: bool("event_filter.rules.low_priority_no_sector.enabled", true),
            lowPriorityMax: int("event_filter.rules.low_priority_no_sector.max_priority", 2),
            lowValueIndividualEnabled: bool("event_filter.rules.low_value_individual.enabled", true),
            lowValueMaxPriority: int("event_filter.rules.low_value_individual.max_priority", 2),
            lowValueMinNewsCount: int("event_filter.rules.low_value_individual.min_news_count", 2),
            alwaysKeepMinPriority: int("event_filter.rules.always_keep.min_priority", 3),
            alwaysKeepNewsCount: int("event_filter.rules.always_keep.or_news_count", 3),
            sourcePriority: priorities.isEmpty ? stockAgentDefaults.sourcePriority : priorities)
    }
}

public struct EventCluster: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let headline: String
    public let eventCount: Int
    public let priority: Int
    public let sourceIDs: [String]
    public let sectors: [String]
    public let stockCodes: [String]
    public let firstPublishedAt: Date?
    public let latestPublishedAt: Date?
    public let eventIDs: [String]

    public init(id: String, headline: String, eventCount: Int, priority: Int,
                sourceIDs: [String], sectors: [String], stockCodes: [String],
                firstPublishedAt: Date?, latestPublishedAt: Date?, eventIDs: [String]) {
        self.id = id
        self.headline = headline
        self.eventCount = eventCount
        self.priority = priority
        self.sourceIDs = sourceIDs
        self.sectors = sectors
        self.stockCodes = stockCodes
        self.firstPublishedAt = firstPublishedAt
        self.latestPublishedAt = latestPublishedAt
        self.eventIDs = eventIDs
    }
}

public struct DailyEventSummary: Codable, Sendable, Equatable {
    public let day: Date
    public let generatedAt: Date
    public let eventCount: Int
    public let clusterCount: Int
    public let priorityCounts: [String: Int]
    public let topSectors: [String]
    public let clusters: [EventCluster]

    public init(day: Date, generatedAt: Date, eventCount: Int, clusterCount: Int,
                priorityCounts: [String: Int], topSectors: [String], clusters: [EventCluster]) {
        self.day = day
        self.generatedAt = generatedAt
        self.eventCount = eventCount
        self.clusterCount = clusterCount
        self.priorityCounts = priorityCounts
        self.topSectors = topSectors
        self.clusters = clusters
    }
}

public struct EventProcessingResult: Sendable {
    public let events: [MarketEvent]
    public let filterTotal: Int
    public let filterKept: Int

    public var filterFiltered: Int { max(0, filterTotal - filterKept) }

    public init(events: [MarketEvent], filterTotal: Int, filterKept: Int) {
        self.events = events
        self.filterTotal = max(0, filterTotal)
        self.filterKept = min(self.filterTotal, max(0, filterKept))
    }
}

public struct EventProcessor: Sendable {
    private let policy: CollectorEventPolicy
    private let sectorTagger: SectorTagger?
    private let dedupeWindow: TimeInterval

    public init(policy: CollectorEventPolicy = .stockAgentDefaults,
                sectorTagger: SectorTagger? = nil, dedupeWindow: TimeInterval = 36 * 60 * 60) {
        self.policy = policy
        self.sectorTagger = sectorTagger
        self.dedupeWindow = max(60, dedupeWindow)
    }

    public func process(_ input: [MarketEvent]) -> [MarketEvent] {
        processWithMetrics(input).events
    }

    public func processWithMetrics(_ input: [MarketEvent]) -> EventProcessingResult {
        let enriched = input.map(enrich).sorted {
            let leftDate = $0.publishedAt ?? $0.fetchedAt
            let rightDate = $1.publishedAt ?? $1.fetchedAt
            return leftDate == rightDate ? $0.id < $1.id : leftDate < rightDate
        }
        var clusters: [[MarketEvent]] = []
        let maxDistance = Int(floor((1 - policy.titleSimilarityThreshold) * 64))
        for event in enriched {
            let eventTime = event.publishedAt ?? event.fetchedAt
            var bestIndex: Int?
            var bestDistance = Int.max
            for index in clusters.indices {
                guard let representative = clusters[index].first else { continue }
                let representativeTime = representative.publishedAt ?? representative.fetchedAt
                guard abs(eventTime.timeIntervalSince(representativeTime)) <= dedupeWindow else { continue }
                let representativeCodes = Set(representative.stockCodes)
                let eventCodes = Set(event.stockCodes)
                if !representativeCodes.isEmpty, !eventCodes.isEmpty,
                   representativeCodes.isDisjoint(with: eventCodes) { continue }
                let distance = SimHash.distance(event.simHash, representative.simHash)
                if distance <= maxDistance && distance < bestDistance {
                    bestIndex = index
                    bestDistance = distance
                }
            }
            if let bestIndex { clusters[bestIndex].append(event) }
            else { clusters.append([event]) }
        }
        let merged = clusters.compactMap(merge)
        let kept = merged.filter(policy.keep)
        let sorted = kept
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                let leftDate = $0.publishedAt ?? $0.fetchedAt
                let rightDate = $1.publishedAt ?? $1.fetchedAt
                return leftDate > rightDate
            }
        return EventProcessingResult(events: sorted, filterTotal: merged.count, filterKept: kept.count)
    }

    public func summary(events: [MarketEvent], day: Date, calendar: Calendar? = nil,
                        generatedAt: Date = Date()) -> DailyEventSummary {
        var chinaCalendar = calendar ?? Calendar(identifier: .gregorian)
        if calendar == nil, let shanghai = TimeZone(identifier: "Asia/Shanghai") { chinaCalendar.timeZone = shanghai }
        let start = chinaCalendar.startOfDay(for: day)
        let end = chinaCalendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        let daily = events.filter {
            let date = $0.publishedAt ?? $0.fetchedAt
            return date >= start && date < end
        }
        let processed = process(daily)
        let clusters = processed.map { event in
            EventCluster(id: event.id, headline: event.title, eventCount: event.duplicateCount,
                priority: event.priority, sourceIDs: event.corroboratingSources,
                sectors: event.sectors, stockCodes: event.stockCodes,
                firstPublishedAt: event.publishedAt, latestPublishedAt: event.latestPublishedAt,
                eventIDs: [event.id])
        }
        var counts: [String: Int] = [:]
        var sectorCounts: [String: Int] = [:]
        for event in processed {
            counts["P\(6 - event.priority)", default: 0] += event.duplicateCount
            for sector in event.sectors { sectorCounts[sector, default: 0] += event.duplicateCount }
        }
        let sectors = sectorCounts.keys.sorted {
            let left = sectorCounts[$0, default: 0], right = sectorCounts[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }.prefix(10)
        return DailyEventSummary(day: start, generatedAt: generatedAt,
            eventCount: daily.reduce(0) { $0 + $1.duplicateCount }, clusterCount: clusters.count,
            priorityCounts: counts, topSectors: Array(sectors), clusters: clusters)
    }

    private func enrich(_ event: MarketEvent) -> MarketEvent {
        let text = [event.title, event.body ?? ""].joined(separator: " ")
        let inferredSectors = sectorTagger?.tags(in: text) ?? []
        let sectors = Array(Set(event.sectors + inferredSectors)).sorted()
        let codes = Array(Set(event.stockCodes + Self.extractStockCodes(text))).sorted()
        let scope: EventImpactScope = !sectors.isEmpty ? .sector : !codes.isEmpty ? .stock : event.impactScope
        return event.withPriority(policy.priority(for: event.sourceID, fallback: event.priority))
            .withEnrichment(sectors: sectors, stockCodes: codes, impactScope: scope)
    }

    private func merge(_ events: [MarketEvent]) -> MarketEvent? {
        guard var result = events.first else { return nil }
        for event in events.dropFirst() { result = result.merging(event) }
        return result
    }

    private static func extractStockCodes(_ text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "(?<![0-9])[03468][0-9]{5}(?![0-9])") else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            return String(text[range])
        }
    }
}

private extension Dictionary where Key == String, Value == Int {
    func mapKeys(_ transform: (String) -> String) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: map { (transform($0.key), $0.value) })
    }
}

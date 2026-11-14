import Foundation

public struct EventRejectionDecision: Codable, Sendable, Equatable {
    public let eventID: String
    public let sourceID: String
    public let reason: String
    public let decidedAt: Date

    public init(eventID: String, sourceID: String, reason: String, decidedAt: Date = Date()) {
        self.eventID = eventID
        self.sourceID = sourceID
        self.reason = reason
        self.decidedAt = decidedAt
    }
}

public struct EventKeywordFrequency: Codable, Sendable, Equatable {
    public let token: String
    public let latestCount: Int
    public let baselineCount: Int
    public let growthPercent: Double?

    public init(token: String, latestCount: Int, baselineCount: Int) {
        self.token = token
        self.latestCount = max(0, latestCount)
        self.baselineCount = max(0, baselineCount)
        growthPercent = baselineCount > 0
            ? (Double(latestCount - baselineCount) / Double(baselineCount)) * 100
            : nil
    }
}

public struct EventKeywordFrequencyReport: Codable, Sendable, Equatable {
    public let latestWindow: DateInterval
    public let baselineWindow: DateInterval
    public let latestSampleCount: Int
    public let baselineSampleCount: Int
    public let missingReasons: [String]
    public let frequencies: [EventKeywordFrequency]

    public init(latestWindow: DateInterval, baselineWindow: DateInterval,
                latestSampleCount: Int, baselineSampleCount: Int,
                missingReasons: [String] = [], frequencies: [EventKeywordFrequency] = []) {
        self.latestWindow = latestWindow
        self.baselineWindow = baselineWindow
        self.latestSampleCount = max(0, latestSampleCount)
        self.baselineSampleCount = max(0, baselineSampleCount)
        self.missingReasons = missingReasons
        self.frequencies = frequencies
    }
}

public enum EventKeywordTokenizer {
    /// Contiguous Han runs produce overlapping bigrams; Latin letters/digits form lowercased runs.
    /// All other scalars delimit terms, avoiding locale- or ICU-version-dependent behavior.
    public static func tokenize(_ text: String) -> [String] {
        var result: [String] = []
        var latin = ""
        var han = ""
        func flush() { if !latin.isEmpty { result.append(latin.lowercased()); latin.removeAll(keepingCapacity: true) } }
        func flushHan() {
            guard !han.isEmpty else { return }
            let scalars = Array(han.unicodeScalars)
            if scalars.count == 1 {
                result.append(String(scalars[0]))
            } else {
                for index in 0..<(scalars.count - 1) {
                    result.append(String(String.UnicodeScalarView([scalars[index], scalars[index + 1]])))
                }
            }
            han.removeAll(keepingCapacity: true)
        }
        for scalar in text.unicodeScalars {
            let value = scalar.value
            if isHan(value) {
                flush(); han.unicodeScalars.append(scalar)
            } else if isLatinOrDigit(value) {
                flushHan(); latin.unicodeScalars.append(scalar)
            } else {
                flushHan(); flush()
            }
        }
        flushHan(); flush()
        return result
    }

    public static func frequencies(events: [MarketEvent]) -> [String: Int] {
        events.reduce(into: [String: Int]()) { counts, event in
            let text = [event.title, event.body ?? ""].joined(separator: " ")
            for token in tokenize(text) where token.count > 1 {
                counts[token, default: 0] += 1
            }
        }
    }

    private static func isLatinOrDigit(_ value: UInt32) -> Bool {
        (value >= 48 && value <= 57) || (value >= 65 && value <= 90) || (value >= 97 && value <= 122)
    }

    private static func isHan(_ value: UInt32) -> Bool {
        (value >= 0x3400 && value <= 0x4DBF) || (value >= 0x4E00 && value <= 0x9FFF) ||
        (value >= 0xF900 && value <= 0xFAFF)
    }
}

public extension EventKeywordFrequencyReport {
    static func compare(events: [MarketEvent], now: Date, window: TimeInterval = 24 * 60 * 60,
                        top: Int = 100) -> EventKeywordFrequencyReport {
        let safeWindow = max(1, window)
        let latest = DateInterval(start: now.addingTimeInterval(-safeWindow), end: now)
        let baseline = DateInterval(start: now.addingTimeInterval(-2 * safeWindow), end: now.addingTimeInterval(-safeWindow))
        func inWindow(_ event: MarketEvent, _ interval: DateInterval) -> Bool {
            interval.contains(event.publishedAt ?? event.fetchedAt)
        }
        let latestEvents = events.filter { inWindow($0, latest) }
        let baselineEvents = events.filter { inWindow($0, baseline) }
        let latestCounts = EventKeywordTokenizer.frequencies(events: latestEvents)
        let baselineCounts = EventKeywordTokenizer.frequencies(events: baselineEvents)
        let tokens = Set(latestCounts.keys).union(baselineCounts.keys)
        let frequencies = tokens.map { token in
            EventKeywordFrequency(token: token, latestCount: latestCounts[token, default: 0], baselineCount: baselineCounts[token, default: 0])
        }.sorted { left, right in
            if left.latestCount != right.latestCount { return left.latestCount > right.latestCount }
            return left.token < right.token
        }
        let limited = Array(frequencies.prefix(max(1, top)))
        var missing: [String] = []
        if latestEvents.isEmpty { missing.append("latest_24h_has_no_events") }
        if baselineEvents.isEmpty { missing.append("preceding_24h_has_no_events") }
        return EventKeywordFrequencyReport(latestWindow: latest, baselineWindow: baseline,
            latestSampleCount: latestEvents.count, baselineSampleCount: baselineEvents.count,
            missingReasons: missing, frequencies: limited)
    }
}

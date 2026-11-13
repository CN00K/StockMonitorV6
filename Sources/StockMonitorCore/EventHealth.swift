import Foundation

public enum SourceHealthThresholds {
    public static let p1SuccessRate = 0.99
    public static let eventValidityRate = 0.80
    public static let llmCallShare = 0.50
    public static let rollingDays = 7
}

/// Daily additive counters. P1 request counts cover only `gov` and `cninfo`; validity is
/// parser-accepted records divided by source candidate records. `llmEnrichedDecisions`
/// counts one successful, user-started Analyst run, not its five parallel requests plus
/// refinement. Each de-duplicated event retained by the local collector and not sent to
/// Analyst increments `ruleOrSkippedDecisions` once. Failed/empty denominators are shown
/// as unavailable in the UI rather than treated as a measured pass.
public struct SourceHealthDelta: Sendable, Equatable {
    public let day: Date
    public let p1Successes: Int
    public let p1Attempts: Int
    public let filterKept: Int
    public let filterTotal: Int
    public let llmEnrichedDecisions: Int
    public let ruleOrSkippedDecisions: Int

    public init(day: Date, p1Successes: Int = 0, p1Attempts: Int = 0,
                filterKept: Int = 0, filterTotal: Int = 0,
                llmEnrichedDecisions: Int = 0, ruleOrSkippedDecisions: Int = 0) {
        self.day = day
        self.p1Successes = max(0, p1Successes)
        self.p1Attempts = max(0, p1Attempts)
        self.filterKept = max(0, filterKept)
        self.filterTotal = max(0, filterTotal)
        self.llmEnrichedDecisions = max(0, llmEnrichedDecisions)
        self.ruleOrSkippedDecisions = max(0, ruleOrSkippedDecisions)
    }
}

public struct SourceHealthSnapshot: Sendable, Equatable {
    public let from: Date
    public let through: Date
    public let p1Successes: Int
    public let p1Attempts: Int
    public let filterKept: Int
    public let filterTotal: Int
    public let llmEnrichedDecisions: Int
    public let ruleOrSkippedDecisions: Int

    public init(from: Date, through: Date, p1Successes: Int = 0, p1Attempts: Int = 0,
                filterKept: Int = 0, filterTotal: Int = 0,
                llmEnrichedDecisions: Int = 0, ruleOrSkippedDecisions: Int = 0) {
        self.from = from
        self.through = through
        self.p1Successes = max(0, p1Successes)
        self.p1Attempts = max(0, p1Attempts)
        self.filterKept = max(0, filterKept)
        self.filterTotal = max(0, filterTotal)
        self.llmEnrichedDecisions = max(0, llmEnrichedDecisions)
        self.ruleOrSkippedDecisions = max(0, ruleOrSkippedDecisions)
    }

    public var p1SuccessRate: Double {
        p1Attempts == 0 ? 1.0 : Double(min(p1Successes, p1Attempts)) / Double(p1Attempts)
    }

    public var eventValidityRate: Double {
        filterTotal == 0 ? 1.0 : Double(min(filterKept, filterTotal)) / Double(filterTotal)
    }

    public var llmCallShare: Double {
        let decisions = llmEnrichedDecisions + ruleOrSkippedDecisions
        return decisions == 0 ? 0.0 : Double(llmEnrichedDecisions) / Double(decisions)
    }

    public var p1ThresholdPassed: Bool { p1SuccessRate >= SourceHealthThresholds.p1SuccessRate }
    public var eventValidityThresholdPassed: Bool { eventValidityRate >= SourceHealthThresholds.eventValidityRate }
    public var llmCallShareThresholdPassed: Bool { llmCallShare <= SourceHealthThresholds.llmCallShare }
}

import Foundation

/// The six independently measured inputs accepted by the local sentiment score.
/// Callers must supply only values they have actually measured; omitted cases remain missing.
public enum LocalMarketSentimentComponent: String, CaseIterable, Codable, Equatable, Sendable {
    /// Normalized advancing-minus-declining breadth.
    case advancingDecliningBreadth
    /// Normalized balance of positive and negative return observations.
    case returnDistribution
    /// Normalized balance of limit-up and limit-down observations.
    case limitUpDownBalance
    /// Normalized pressure from stocks that opened after reaching the upper limit.
    case sealBreakPressure
    /// Normalized direction of measured main-fund/net money flow.
    case moneyFlowDirection
    /// Normalized participation/coverage quality of the measured market sample.
    case marketParticipation
}

/// Provenance and sampling context for one caller-measured sentiment input.
public struct LocalMarketSentimentMetadata: Equatable, Sendable {
    public let provenance: String
    public let sampleDescription: String
    public let sampleCount: Int?
    public let measuredAt: Date?

    public init(provenance: String, sampleDescription: String, sampleCount: Int? = nil,
                measuredAt: Date? = nil) {
        self.provenance = provenance
        self.sampleDescription = sampleDescription
        self.sampleCount = sampleCount
        self.measuredAt = measuredAt
    }
}

/// A caller-supplied, normalized component observation. No component is inferred or fetched.
public struct LocalMarketSentimentObservation: Equatable, Sendable {
    public let score: Double
    public let weight: Double
    public let metadata: LocalMarketSentimentMetadata

    public init(score: Double, weight: Double = 1,
                metadata: LocalMarketSentimentMetadata) {
        self.score = score
        self.weight = weight
        self.metadata = metadata
    }
}

public enum LocalMarketSentimentExclusionReason: String, Equatable, Sendable {
    case missing
    case invalidScore
    case invalidWeight
}

public struct LocalMarketSentimentExclusion: Equatable, Sendable {
    public let component: LocalMarketSentimentComponent
    public let reason: LocalMarketSentimentExclusionReason

    public init(component: LocalMarketSentimentComponent,
                reason: LocalMarketSentimentExclusionReason) {
        self.component = component
        self.reason = reason
    }
}

/// Descriptive display bands for a normalized score; labels are not predictions.
public enum LocalMarketSentimentBand: String, CaseIterable, Equatable, Sendable {
    /// score < -0.60
    case veryWeak = "Very weak"
    /// -0.60 <= score < -0.20
    case weak = "Weak"
    /// -0.20 <= score < 0.20
    case balanced = "Balanced"
    /// 0.20 <= score < 0.60
    case strong = "Strong"
    /// score >= 0.60
    case veryStrong = "Very strong"

    public static func forScore(_ score: Double) -> Self? {
        guard score.isFinite, (-1...1).contains(score) else { return nil }
        switch score {
        case ..<(-0.6): return .veryWeak
        case -0.6..<(-0.2): return .weak
        case -0.2..<0.2: return .balanced
        case 0.2..<0.6: return .strong
        default: return .veryStrong
        }
    }
}

public struct LocalMarketSentimentResult: Equatable, Sendable {
    /// Nil means no valid measured component was supplied.
    public let score: Double?
    /// Nil whenever `score` is nil.
    public let band: LocalMarketSentimentBand?
    public let includedComponents: [LocalMarketSentimentComponent]
    public let excludedComponents: [LocalMarketSentimentExclusion]

    public init(score: Double?, band: LocalMarketSentimentBand?,
                includedComponents: [LocalMarketSentimentComponent],
                excludedComponents: [LocalMarketSentimentExclusion]) {
        self.score = score
        self.band = band
        self.includedComponents = includedComponents
        self.excludedComponents = excludedComponents
    }
}

/// Pure local aggregation of caller-measured A-share market sentiment inputs.
public enum LocalMarketSentiment {
    /// Computes a weighted mean over valid supplied components only.
    /// Scores must be finite and in [-1, 1]. Weights must be finite and non-negative.
    /// Missing or invalid components are excluded and reported; remaining weights are
    /// implicitly renormalized by dividing by their sum. No data is fetched or inferred.
    public static func score(
        _ observations: [LocalMarketSentimentComponent: LocalMarketSentimentObservation]
    ) -> LocalMarketSentimentResult {
        var included: [(LocalMarketSentimentComponent, LocalMarketSentimentObservation)] = []
        var excluded: [LocalMarketSentimentExclusion] = []

        for component in LocalMarketSentimentComponent.allCases {
            guard let observation = observations[component] else {
                excluded.append(.init(component: component, reason: .missing))
                continue
            }
            guard observation.score.isFinite, (-1...1).contains(observation.score) else {
                excluded.append(.init(component: component, reason: .invalidScore))
                continue
            }
            guard observation.weight.isFinite, observation.weight >= 0 else {
                excluded.append(.init(component: component, reason: .invalidWeight))
                continue
            }
            included.append((component, observation))
        }

        let totalWeight = included.reduce(0.0) { $0 + $1.1.weight }
        guard totalWeight.isFinite, totalWeight > 0 else {
            return .init(score: nil, band: nil,
                         includedComponents: [], excludedComponents: excluded)
        }
        let weightedTotal = included.reduce(0.0) { $0 + $1.1.score * $1.1.weight }
        let normalized = weightedTotal / totalWeight
        return .init(score: normalized, band: .forScore(normalized),
                     includedComponents: included.map(\.0), excludedComponents: excluded)
    }
}

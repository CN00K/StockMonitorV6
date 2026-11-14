import Foundation

public struct LocalBacktestBootstrapResult: Sendable, Equatable {
    public let sampleReturnCount: Int
    public let pathCount: Int
    public let horizon: Int
    /// Multiplicative equity levels; arrays include the initial level 1.0.
    public let lower5Equity: [Double]
    public let medianEquity: [Double]
    public let upper95Equity: [Double]
    /// Maximum peak-to-trough drawdown fractions across simulated paths.
    public let medianMaximumDrawdown: Double
    public let maximumDrawdown95: Double
    public let seed: UInt64
    public let warnings: [String]

    public init(sampleReturnCount: Int, pathCount: Int, horizon: Int,
                lower5Equity: [Double], medianEquity: [Double], upper95Equity: [Double],
                medianMaximumDrawdown: Double, maximumDrawdown95: Double,
                seed: UInt64, warnings: [String]) {
        self.sampleReturnCount = sampleReturnCount
        self.pathCount = pathCount
        self.horizon = horizon
        self.lower5Equity = lower5Equity
        self.medianEquity = medianEquity
        self.upper95Equity = upper95Equity
        self.medianMaximumDrawdown = medianMaximumDrawdown
        self.maximumDrawdown95 = maximumDrawdown95
        self.seed = seed
        self.warnings = warnings
    }
}

/// Simple IID bootstrap over a caller-supplied local return sequence. This is a
/// sensitivity analysis, not a forecast; it does not model serial dependence,
/// corporate actions, survivorship, liquidity, or future regime changes.
public enum LocalBacktestBootstrap {
    public static func run(returns: [Double], pathCount requestedPaths: Int = 1_000,
                           horizon requestedHorizon: Int? = nil, seed: UInt64 = 1)
        -> LocalBacktestBootstrapResult? {
        guard !returns.isEmpty, returns.allSatisfy({ $0.isFinite && $0 >= -1 }) else { return nil }
        let horizon = min(1_000, requestedHorizon ?? returns.count)
        guard horizon > 0 else { return nil }
        let pathCount = min(2_000, max(1, requestedPaths))
        var generator = SplitMix64(state: seed)
        var curves = [[Double]]()
        curves.reserveCapacity(pathCount)
        var maximumDrawdowns = [Double]()
        maximumDrawdowns.reserveCapacity(pathCount)

        for _ in 0..<pathCount {
            var curve = [1.0]
            curve.reserveCapacity(horizon + 1)
            var equity = 1.0
            var peak = 1.0
            var maximumDrawdown = 0.0
            for _ in 0..<horizon {
                let sampledReturn = returns[Int.random(in: returns.indices, using: &generator)]
                equity *= 1 + sampledReturn
                guard equity.isFinite, equity >= 0 else { return nil }
                peak = max(peak, equity)
                if peak > 0 { maximumDrawdown = max(maximumDrawdown, 1 - equity / peak) }
                curve.append(equity)
            }
            curves.append(curve)
            maximumDrawdowns.append(maximumDrawdown)
        }

        var lower = [Double]()
        var median = [Double]()
        var upper = [Double]()
        lower.reserveCapacity(horizon + 1)
        median.reserveCapacity(horizon + 1)
        upper.reserveCapacity(horizon + 1)
        for step in 0...horizon {
            let sorted = curves.map { $0[step] }.sorted()
            lower.append(quantile(sorted, probability: 0.05))
            median.append(quantile(sorted, probability: 0.50))
            upper.append(quantile(sorted, probability: 0.95))
        }
        maximumDrawdowns.sort()
        return LocalBacktestBootstrapResult(sampleReturnCount: returns.count,
            pathCount: pathCount, horizon: horizon, lower5Equity: lower,
            medianEquity: median, upper95Equity: upper,
            medianMaximumDrawdown: quantile(maximumDrawdowns, probability: 0.50),
            maximumDrawdown95: quantile(maximumDrawdowns, probability: 0.95), seed: seed,
            warnings: ["IID bootstrap with replacement; historical sample only, not a forecast or investment advice.",
                       "Serial dependence, corporate actions, survivorship, transaction costs, liquidity, and regime changes are not modeled."])
    }

    private static func quantile(_ sorted: [Double], probability: Double) -> Double {
        guard sorted.count > 1 else { return sorted.first ?? 0 }
        let position = probability * Double(sorted.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = min(sorted.count - 1, lowerIndex + 1)
        let fraction = position - Double(lowerIndex)
        return sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction
    }
}

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }
}

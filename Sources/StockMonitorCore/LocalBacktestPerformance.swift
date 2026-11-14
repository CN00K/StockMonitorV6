import Foundation

public struct LocalBacktestMonthPerformance: Codable, Sendable, Equatable, Identifiable {
    public let month: String
    public let returnFraction: Double
    public let sessionCount: Int
    public var id: String { month }

    public init(month: String, returnFraction: Double, sessionCount: Int) {
        self.month = month
        self.returnFraction = returnFraction
        self.sessionCount = sessionCount
    }
}

/// Risk/performance summaries for an existing equal-weight factor stratum curve.
/// These are descriptive statistics, not a position-level strategy simulation.
public struct LocalBacktestPerformanceMetrics: Sendable, Equatable {
    public let observationCount: Int
    public let cumulativeReturn: Double?
    public let annualizedReturn: Double?
    public let annualizedVolatility: Double?
    public let sharpeRatioZeroRiskFree: Double?
    public let maximumDrawdown: Double?
    public let calmarRatio: Double?
    public let winRate: Double?
    public let profitLossRatio: Double?
    public let returnP05: Double?
    public let returnP25: Double?
    public let returnP50: Double?
    public let returnP75: Double?
    public let returnP95: Double?
    public let monthlyReturns: [LocalBacktestMonthPerformance]

    public init(observationCount: Int, cumulativeReturn: Double?, annualizedReturn: Double?,
                annualizedVolatility: Double?, sharpeRatioZeroRiskFree: Double?,
                maximumDrawdown: Double?, calmarRatio: Double?, winRate: Double?,
                profitLossRatio: Double?, returnP05: Double?, returnP25: Double?,
                returnP50: Double?, returnP75: Double?, returnP95: Double?,
                monthlyReturns: [LocalBacktestMonthPerformance]) {
        self.observationCount = observationCount
        self.cumulativeReturn = cumulativeReturn
        self.annualizedReturn = annualizedReturn
        self.annualizedVolatility = annualizedVolatility
        self.sharpeRatioZeroRiskFree = sharpeRatioZeroRiskFree
        self.maximumDrawdown = maximumDrawdown
        self.calmarRatio = calmarRatio
        self.winRate = winRate
        self.profitLossRatio = profitLossRatio
        self.returnP05 = returnP05
        self.returnP25 = returnP25
        self.returnP50 = returnP50
        self.returnP75 = returnP75
        self.returnP95 = returnP95
        self.monthlyReturns = monthlyReturns
    }
}

public enum LocalBacktestPerformanceAnalyzer {
    /// Computes descriptive metrics from a LocalBacktestStratum's equal-weight
    /// cross-sectional daily-return equity curve. Sharpe assumes zero risk-free
    /// rate and 252 sessions/year. It does not infer turnover or benchmark excess.
    public static func analyze(_ stratum: LocalBacktestStratum) -> LocalBacktestPerformanceMetrics {
        let curve = stratum.equityCurve
        let returns = dailyReturns(from: curve)
        let count = returns.count
        let first = curve.first.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let last = curve.last.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let cumulative: Double? = {
            guard let first, let last else { return nil }
            return finite(last / first - 1)
        }()
        let annualized: Double? = {
            guard let first, let last, count > 0, first > 0, last > 0 else { return nil }
            let value = pow(last / first, 252.0 / Double(count)) - 1
            return finite(value)
        }()
        let mean = count > 0 ? returns.reduce(0, +) / Double(count) : nil
        let deviation = sampleStandardDeviation(returns)
        let annualizedVolatility = deviation.flatMap { finite($0 * sqrt(252.0)) }
        let sharpe: Double? = {
            guard let mean, let deviation, deviation > 0 else { return nil }
            return finite(mean / deviation * sqrt(252.0))
        }()
        let drawdown = maximumDrawdown(curve)
        let calmar: Double? = {
            guard let annualized, let drawdown, drawdown > 0 else { return nil }
            return finite(annualized / drawdown)
        }()
        let wins = returns.filter { $0 > 0 }
        let losses = returns.filter { $0 < 0 }
        let winRate = count > 0 ? Double(wins.count) / Double(count) : nil
        let profitLoss: Double? = {
            guard !wins.isEmpty, !losses.isEmpty else { return nil }
            let averageGain = wins.reduce(0, +) / Double(wins.count)
            let averageLoss = abs(losses.reduce(0, +) / Double(losses.count))
            guard averageLoss > 0 else { return nil }
            return finite(averageGain / averageLoss)
        }()
        let monthly = monthlyReturns(curve: curve, dates: stratum.equityCurveDates)

        return LocalBacktestPerformanceMetrics(observationCount: count,
            cumulativeReturn: cumulative, annualizedReturn: annualized,
            annualizedVolatility: annualizedVolatility, sharpeRatioZeroRiskFree: sharpe,
            maximumDrawdown: drawdown, calmarRatio: calmar, winRate: winRate,
            profitLossRatio: profitLoss, returnP05: quantile(returns, probability: 0.05),
            returnP25: quantile(returns, probability: 0.25), returnP50: quantile(returns, probability: 0.50),
            returnP75: quantile(returns, probability: 0.75), returnP95: quantile(returns, probability: 0.95),
            monthlyReturns: monthly)
    }

    public static func dailyReturns(from equityCurve: [Double]) -> [Double] {
        guard equityCurve.count >= 2 else { return [] }
        return (1..<equityCurve.count).compactMap { index in
            let previous = equityCurve[index - 1]
            let current = equityCurve[index]
            guard previous.isFinite, current.isFinite, previous > 0 else { return nil }
            return finite(current / previous - 1)
        }
    }

    private static func maximumDrawdown(_ curve: [Double]) -> Double? {
        var peak = -Double.infinity
        var maximum = 0.0
        var observed = false
        for equity in curve where equity.isFinite && equity >= 0 {
            observed = true
            peak = max(peak, equity)
            guard peak > 0 else { continue }
            maximum = max(maximum, 1 - equity / peak)
        }
        return observed ? finite(maximum) : nil
    }

    private static func monthlyReturns(curve: [Double], dates: [Date]) -> [LocalBacktestMonthPerformance] {
        guard curve.count >= 2, dates.count == curve.count - 1 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM"

        var compounded: [String: (value: Double, count: Int)] = [:]
        for index in 1..<curve.count {
            let previous = curve[index - 1]
            let current = curve[index]
            guard previous.isFinite, current.isFinite, previous > 0 else { continue }
            let value = current / previous - 1
            guard value.isFinite else { continue }
            let month = formatter.string(from: dates[index - 1])
            var existing = compounded[month] ?? (1, 0)
            existing.value *= 1 + value
            existing.count += 1
            compounded[month] = existing
        }
        return compounded.keys.sorted().compactMap { month in
            guard let item = compounded[month], item.value.isFinite else { return nil }
            return LocalBacktestMonthPerformance(month: month,
                returnFraction: item.value - 1, sessionCount: item.count)
        }
    }

    private static func sampleStandardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        guard variance.isFinite, variance >= 0 else { return nil }
        return sqrt(variance)
    }

    private static func quantile(_ values: [Double], probability: Double) -> Double? {
        guard !values.isEmpty, probability.isFinite else { return nil }
        let sorted = values.sorted()
        let clamped = min(1, max(0, probability))
        let position = clamped * Double(sorted.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = min(sorted.count - 1, lowerIndex + 1)
        let fraction = position - Double(lowerIndex)
        return finite(sorted[lowerIndex] + (sorted[upperIndex] - sorted[lowerIndex]) * fraction)
    }

    private static func finite(_ value: Double) -> Double? {
        value.isFinite ? value : nil
    }
}

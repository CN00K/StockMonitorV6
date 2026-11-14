import Foundation

public struct LocalBacktestDistributionPoint: Codable, Sendable, Equatable {
    public let date: Date
    public let value: Double

    public init(date: Date, value: Double) {
        self.date = date
        self.value = value
    }
}

public struct LocalBacktestDistributionQuantiles: Codable, Sendable, Equatable {
    public let p05: Double?
    public let p25: Double?
    public let p50: Double?
    public let p75: Double?
    public let p95: Double?
    public let minimum: Double?
    public let maximum: Double?

    public init(p05: Double?, p25: Double?, p50: Double?, p75: Double?, p95: Double?,
                minimum: Double?, maximum: Double?) {
        self.p05 = p05
        self.p25 = p25
        self.p50 = p50
        self.p75 = p75
        self.p95 = p95
        self.minimum = minimum
        self.maximum = maximum
    }
}

/// Trade activity, not P&L attribution. A filled execution record supports quantity
/// and notional reporting but does not by itself establish realized symbol contribution.
public struct LocalBacktestSymbolTradeActivity: Codable, Sendable, Equatable {
    public let symbol: String
    public let tradedNotional: Double
    public let filledQuantity: Int
    public let fillCount: Int

    public init(symbol: String, tradedNotional: Double, filledQuantity: Int, fillCount: Int) {
        self.symbol = symbol
        self.tradedNotional = tradedNotional
        self.filledQuantity = filledQuantity
        self.fillCount = fillCount
    }
}

/// Realized P&L attribution for one symbol. The current execution report does not
/// contain paired open/close records, so summaries leave this collection unknown.
public struct LocalBacktestSymbolContribution: Codable, Sendable, Equatable {
    public let symbol: String
    public let realizedProfitLoss: Double
    public let contributionFraction: Double?

    public init(symbol: String, realizedProfitLoss: Double, contributionFraction: Double?) {
        self.symbol = symbol
        self.realizedProfitLoss = realizedProfitLoss
        self.contributionFraction = contributionFraction
    }
}

public struct LocalBacktestDistributionSummary: Codable, Sendable, Equatable {
    public let observationCount: Int
    public let cumulativeReturn: Double?
    public let benchmarkReturn: Double?
    public let excessReturn: Double?
    /// Nil unless actual portfolio NAV and trade-side/holding transitions are present.
    public let turnover: Double?
    /// Gross notional from actual filled trade records; not a turnover ratio or P&L.
    public let grossTradedNotional: Double?
    public let holdingDurationSessions: Double?
    /// Nil unless paired/open-close trade records support realized P&L attribution.
    public let symbolContributions: [LocalBacktestSymbolContribution]?
    public let symbolTradeActivity: [LocalBacktestSymbolTradeActivity]?
    /// Stable reasons for each unavailable summary value.
    public let unavailableReasons: [String: String]

    public init(observationCount: Int, cumulativeReturn: Double?, excessReturn: Double?,
                benchmarkReturn: Double? = nil,
                turnover: Double?, grossTradedNotional: Double?, holdingDurationSessions: Double?,
                symbolContributions: [LocalBacktestSymbolContribution]?,
                symbolTradeActivity: [LocalBacktestSymbolTradeActivity]?,
                unavailableReasons: [String: String]) {
        self.observationCount = observationCount
        self.cumulativeReturn = cumulativeReturn
        self.benchmarkReturn = benchmarkReturn
        self.excessReturn = excessReturn
        self.turnover = turnover
        self.grossTradedNotional = grossTradedNotional
        self.holdingDurationSessions = holdingDurationSessions
        self.symbolContributions = symbolContributions
        self.symbolTradeActivity = symbolTradeActivity
        self.unavailableReasons = unavailableReasons
    }
}

public struct LocalBacktestDistributionDataset: Codable, Sendable, Equatable {
    public let stratumIndex: Int
    public let dailyReturns: [LocalBacktestDistributionPoint]
    public let dailyExcessReturns: [LocalBacktestDistributionPoint]
    public let quantiles: LocalBacktestDistributionQuantiles
    public let monthlyReturns: [LocalBacktestMonthPerformance]
    public let summary: LocalBacktestDistributionSummary
    public let warnings: [String]

    public init(stratumIndex: Int, dailyReturns: [LocalBacktestDistributionPoint],
                dailyExcessReturns: [LocalBacktestDistributionPoint] = [],
                quantiles: LocalBacktestDistributionQuantiles,
                monthlyReturns: [LocalBacktestMonthPerformance],
                summary: LocalBacktestDistributionSummary, warnings: [String] = []) {
        self.stratumIndex = stratumIndex
        self.dailyReturns = dailyReturns
        self.dailyExcessReturns = dailyExcessReturns
        self.quantiles = quantiles
        self.monthlyReturns = monthlyReturns
        self.summary = summary
        self.warnings = warnings
    }
}

/// Builds deterministic chart/report datasets from already-recorded local backtest data.
/// It never reconstructs trades, holdings, benchmark prices, or P&L from an equity curve.
public enum LocalBacktestDistribution {
    public static func build(report: LocalBacktestReport, stratumIndex: Int = 1,
                             benchmarkBars: [DailyBar]? = nil,
                             execution: AshareExecutionBacktestReport? = nil) -> LocalBacktestDistributionDataset {
        guard let stratum = report.strata.first(where: { $0.index == stratumIndex }) else {
            let empty = LocalBacktestDistributionQuantiles(p05: nil, p25: nil, p50: nil,
                p75: nil, p95: nil, minimum: nil, maximum: nil)
            let summary = LocalBacktestDistributionSummary(observationCount: 0,
                cumulativeReturn: nil, excessReturn: nil, turnover: nil, grossTradedNotional: nil,
                holdingDurationSessions: nil, symbolContributions: nil, symbolTradeActivity: nil,
                unavailableReasons: [
                    "stratum": "Requested stratum is absent from LocalBacktestReport; no distribution was reconstructed.",
                    "benchmark": "No strategy observations exist for date alignment.",
                    "turnover": "No actual portfolio NAV or trade-side/holding transitions were supplied.",
                    "grossTradedNotional": "No actual filled execution records were supplied.",
                    "holdingDuration": "No explicit paired open/close trade records were supplied.",
                    "symbolContributions": "No explicit paired open/close trade records with realized P&L were supplied."
                ])
            return LocalBacktestDistributionDataset(stratumIndex: stratumIndex, dailyReturns: [], dailyExcessReturns: [],
                quantiles: empty, monthlyReturns: [], summary: summary, warnings: report.warnings)
        }

        let rawReturns = LocalBacktestPerformanceAnalyzer.dailyReturns(from: stratum.equityCurve)
        let points = zip(stratum.equityCurveDates, rawReturns)
            .filter { $0.1.isFinite }
            .map { LocalBacktestDistributionPoint(date: $0.0, value: $0.1) }
            .sorted { $0.date < $1.date }
        let values = points.map(\.value)
        let q = quantiles(values)
        var reasons: [String: String] = [:]
        let benchmark = alignedBenchmark(strategy: points, benchmarkBars: benchmarkBars, reason: &reasons)
        let trades = tradeActivity(execution, reasons: &reasons)
        let cumulative = stratum.equityCurve.first.flatMap { first in
            stratum.equityCurve.last.flatMap { last in
                first > 0 && first.isFinite && last.isFinite ? last / first - 1 : nil
            }
        }
        if execution == nil {
            reasons["grossTradedNotional"] = "No actual filled execution records were supplied; traded notional is unknown."
            reasons["symbolTradeActivity"] = "No actual filled execution records were supplied; symbol trade activity is unknown."
        }
        reasons["turnover"] = "Turnover is unknown because records do not supply portfolio NAV and complete trade-side/holding transitions."
        reasons["holdingDuration"] = "Holding duration is unknown because records do not contain explicit paired open/close trades."
        reasons["symbolContributions"] = "Realized per-symbol P&L contribution is unknown because records do not contain paired open/close trades and realized P&L."
        let monthly = LocalBacktestPerformanceAnalyzer.analyze(stratum).monthlyReturns
        let summary = LocalBacktestDistributionSummary(observationCount: values.count,
            cumulativeReturn: cumulative, excessReturn: benchmark?.excessReturn,
            benchmarkReturn: benchmark?.benchmarkReturn, turnover: nil,
            grossTradedNotional: trades.grossNotional, holdingDurationSessions: nil,
            symbolContributions: nil, symbolTradeActivity: trades.bySymbol,
            unavailableReasons: reasons)
        return LocalBacktestDistributionDataset(stratumIndex: stratumIndex, dailyReturns: points,
            dailyExcessReturns: benchmark?.dailyExcessReturns ?? [],
            quantiles: q, monthlyReturns: monthly, summary: summary, warnings: report.warnings)
    }

    public static func build(report: LocalBacktestExecutionReport, stratumIndex: Int = 1,
                             benchmarkBars: [DailyBar]? = nil) -> LocalBacktestDistributionDataset {
        let base = build(report: report.gross, stratumIndex: stratumIndex,
                         benchmarkBars: benchmarkBars, execution: report.execution)
        return LocalBacktestDistributionDataset(stratumIndex: base.stratumIndex,
            dailyReturns: base.dailyReturns, dailyExcessReturns: base.dailyExcessReturns,
            quantiles: base.quantiles,
            monthlyReturns: base.monthlyReturns, summary: base.summary,
            warnings: base.warnings + report.warnings)
    }

    private static func quantiles(_ values: [Double]) -> LocalBacktestDistributionQuantiles {
        let sorted = values.filter(\.isFinite).sorted()
        func q(_ p: Double) -> Double? {
            guard !sorted.isEmpty else { return nil }
            let position = p * Double(sorted.count - 1)
            let low = Int(floor(position))
            let high = min(sorted.count - 1, low + 1)
            return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
        }
        return LocalBacktestDistributionQuantiles(p05: q(0.05), p25: q(0.25), p50: q(0.5),
            p75: q(0.75), p95: q(0.95), minimum: sorted.first, maximum: sorted.last)
    }

    private struct BenchmarkAlignment {
        let benchmarkReturn: Double
        let excessReturn: Double
        let dailyExcessReturns: [LocalBacktestDistributionPoint]
    }

    private static func alignedBenchmark(strategy: [LocalBacktestDistributionPoint],
                                         benchmarkBars: [DailyBar]?,
                                         reason: inout [String: String]) -> BenchmarkAlignment? {
        guard let benchmarkBars else {
            reason["benchmark"] = "Benchmark bars were not explicitly supplied; excess return is unknown."
            return nil
        }
        let codes = Set(benchmarkBars.map(\.code))
        guard codes.count == 1 else {
            reason["benchmark"] = "Benchmark bars must contain exactly one explicitly supplied symbol."
            return nil
        }
        let bars = benchmarkBars.sorted { $0.tradeDate < $1.tradeDate }
        guard bars.count >= 2, Set(bars.map(\.tradeDate)).count == bars.count else {
            reason["benchmark"] = "Benchmark needs at least two unique dated bars; excess return is unknown."
            return nil
        }
        var returns: [Date: Double] = [:]
        for index in 1..<bars.count {
            let previous = bars[index - 1].close
            let current = bars[index].close
            guard previous.isFinite, current.isFinite, previous > 0, current > 0 else { continue }
            returns[bars[index].tradeDate] = current / previous - 1
        }
        let aligned = strategy.compactMap { point -> (LocalBacktestDistributionPoint, Double)? in
            returns[point.date].map { (point, $0) }
        }
        guard aligned.count == strategy.count, !aligned.isEmpty else {
            reason["benchmark"] = "Benchmark bars do not provide a valid return for every strategy date; excess return is unknown."
            return nil
        }
        var strategyGrowth = 1.0
        var benchmarkGrowth = 1.0
        var dailyExcess: [LocalBacktestDistributionPoint] = []
        for (point, benchmarkDailyReturn) in aligned {
            guard point.value.isFinite, point.value >= -1,
                  benchmarkDailyReturn.isFinite, benchmarkDailyReturn >= -1 else {
                reason["benchmark"] = "Aligned return series contains an invalid value; excess return is unknown."
                return nil
            }
            strategyGrowth *= 1 + point.value
            benchmarkGrowth *= 1 + benchmarkDailyReturn
            dailyExcess.append(LocalBacktestDistributionPoint(date: point.date,
                value: point.value - benchmarkDailyReturn))
        }
        guard strategyGrowth.isFinite, benchmarkGrowth.isFinite else {
            reason["benchmark"] = "Compounded return overflowed finite numeric range; excess return is unknown."
            return nil
        }
        return BenchmarkAlignment(benchmarkReturn: benchmarkGrowth - 1,
            excessReturn: strategyGrowth - benchmarkGrowth, dailyExcessReturns: dailyExcess)
    }

    private static func tradeActivity(_ execution: AshareExecutionBacktestReport?,
                                     reasons: inout [String: String]) ->
        (grossNotional: Double?, bySymbol: [LocalBacktestSymbolTradeActivity]?) {
        guard let execution else { return (nil, nil) }
        let filled = execution.events.filter(\.filled)
        guard !filled.isEmpty else {
            reasons["grossTradedNotional"] = "The supplied execution report contains no filled trade records."
            reasons["symbolTradeActivity"] = "The supplied execution report contains no filled trade records."
            return (0, [])
        }
        var totals: [String: (notional: Double, quantity: Int, count: Int)] = [:]
        var totalNotional = 0.0
        for event in filled {
            guard let price = event.roundedPrice, price.isFinite, price >= 0 else {
                reasons["grossTradedNotional"] = "At least one filled record lacks a valid rounded execution price."
                return (nil, nil)
            }
            let notional = price * Double(event.filledQuantity)
            guard notional.isFinite else {
                reasons["grossTradedNotional"] = "Filled notional overflowed finite numeric range."
                return (nil, nil)
            }
            totalNotional += notional
            var item = totals[event.order.code] ?? (0, 0, 0)
            item.notional += notional
            item.quantity += event.filledQuantity
            item.count += 1
            totals[event.order.code] = item
        }
        let activity = totals.keys.sorted().compactMap { symbol -> LocalBacktestSymbolTradeActivity? in
            guard let item = totals[symbol] else { return nil }
            return LocalBacktestSymbolTradeActivity(symbol: symbol, tradedNotional: item.notional,
                filledQuantity: item.quantity, fillCount: item.count)
        }
        return (totalNotional, activity)
    }
}

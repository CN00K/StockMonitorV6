import Foundation

/// Unadjusted daily OHLCV data used by the offline backtester.
public struct DailyBar: Codable, Sendable, Equatable {
    public let code: String
    public let name: String
    public let tradeDate: Date
    public let open: Double
    public let high: Double
    public let low: Double
    public let close: Double
    public let volume: Int64
    public let amount: Double?
    public let turnoverRate: Double?
    public let sourceID: String
    public let fetchedAt: Date
    /// Corporate-action adjustment mode. The only supported value is "none".
    public let priceAdjustment: String

    public init(code: String, name: String, tradeDate: Date, open: Double, high: Double,
                low: Double, close: Double, volume: Int64, amount: Double? = nil,
                turnoverRate: Double? = nil, sourceID: String = "unknown",
                fetchedAt: Date = Date(), priceAdjustment: String = "none") {
        self.code = code; self.name = name; self.tradeDate = tradeDate
        self.open = open; self.high = high; self.low = low; self.close = close
        self.volume = volume; self.amount = amount; self.turnoverRate = turnoverRate
        self.sourceID = sourceID; self.fetchedAt = fetchedAt
        self.priceAdjustment = priceAdjustment
    }
}

public struct LocalBacktestStratum: Codable, Sendable, Equatable {
    public let index: Int
    public let sampleCount: Int
    public let averageDailyReturn: Double?
    public let cumulativeReturn: Double?
    public let equityCurve: [Double]
    public let equityCurveDates: [Date]

    public init(index: Int, sampleCount: Int, averageDailyReturn: Double?,
                cumulativeReturn: Double?, equityCurve: [Double], equityCurveDates: [Date] = []) {
        self.index = index; self.sampleCount = sampleCount
        self.averageDailyReturn = averageDailyReturn
        self.cumulativeReturn = cumulativeReturn; self.equityCurve = equityCurve
        self.equityCurveDates = equityCurveDates
    }
}

public struct LocalBacktestICPoint: Codable, Sendable, Equatable {
    public let tradeDate: Date
    public let value: Double
    public let sampleCount: Int

    public init(tradeDate: Date, value: Double, sampleCount: Int) {
        self.tradeDate = tradeDate; self.value = value; self.sampleCount = sampleCount
    }
}

public struct LocalBacktestReport: Codable, Sendable, Equatable {
    public let factor: FactorID
    public let sampleSessions: Int
    public let strataCount: Int
    public let strata: [LocalBacktestStratum]
    public let icSeries: [LocalBacktestICPoint]
    public let meanIC: Double?
    public let icStandardDeviation: Double?
    public let icir: Double?
    public let warnings: [String]

    public init(factor: FactorID, sampleSessions: Int, strataCount: Int,
                strata: [LocalBacktestStratum], icSeries: [LocalBacktestICPoint],
                meanIC: Double?, icStandardDeviation: Double?, icir: Double?,
                warnings: [String]) {
        self.factor = factor; self.sampleSessions = sampleSessions; self.strataCount = strataCount
        self.strata = strata; self.icSeries = icSeries; self.meanIC = meanIC
        self.icStandardDeviation = icStandardDeviation; self.icir = icir; self.warnings = warnings
    }
}

/// Deterministic, offline single-factor cross-sectional backtest.
public struct LocalBacktest: Sendable {
    public init() {}

    public func run(bars: [DailyBar], factor: FactorID, sampleSessions: Int = 20) -> LocalBacktestReport {
        Self.run(bars: bars, factor: factor, sampleSessions: sampleSessions)
    }

    public static func run(bars: [DailyBar], factor: FactorID, sampleSessions: Int = 20) -> LocalBacktestReport {
        let allowed: Set<FactorID> = [.momentum5, .momentum20, .momentum60, .volatility20,
                                      .volatility60, .turnover20, .amount20, .maDeviation20, .rsi14]
        var warnings = ["Prices are unadjusted; no transaction costs, delisting survivorship correction, or authoritative benchmark is applied."]
        let sessions = max(0, sampleSessions)
        guard allowed.contains(factor) else {
            warnings.append("Factor \(factor.rawValue) is unavailable from daily data and was excluded.")
            return LocalBacktestReport(factor: factor, sampleSessions: sessions, strataCount: 0,
                                       strata: [], icSeries: [], meanIC: nil, icStandardDeviation: nil,
                                       icir: nil, warnings: warnings)
        }
        let unadjustedBars = bars.filter { $0.priceAdjustment == "none" }
        let grouped = Dictionary(grouping: unadjustedBars, by: \.code)
            .mapValues { $0.sorted { $0.tradeDate < $1.tradeDate } }
        let dates = Set(unadjustedBars.map(\.tradeDate)).sorted()
        // Include one terminal quote date so each requested signal session can have a next-session return.
        let selectedDates = sessions == 0 ? [] : Array(dates.suffix(sessions + 1))
        if selectedDates.count < sessions + 1 {
            warnings.append("Fewer distinct trading dates than requested; missing dates are not reconstructed.")
        }
        if selectedDates.count < 3 { warnings.append("Small universe/session sample: fewer than 3 represented sessions.") }

        var observations: [Date: [(code: String, factor: Double, forward: Double)]] = [:]
        var missingForward = false
        for date in selectedDates {
            for (code, codeBars) in grouped.sorted(by: { $0.key < $1.key }) {
                guard let position = codeBars.firstIndex(where: { $0.tradeDate == date }),
                      let value = FactorSubset.value(for: factor, observations: codeBars[...position].map {
                          FactorObservation(close: $0.close, high: $0.high, low: $0.low,
                                            amount: $0.amount, turnoverRate: $0.turnoverRate)
                      }), value.isFinite else { continue }
                // The forward bar must be on the immediately next global session, not a later code bar.
                guard let nextDate = dates.first(where: { $0 > date }),
                      let next = codeBars.first(where: { $0.tradeDate == nextDate }),
                      next.close.isFinite, next.close > 0, codeBars[position].close > 0 else {
                    if dates.first(where: { $0 > date }) != nil { missingForward = true }
                    continue
                }
                observations[date, default: []].append((code, value, next.close / codeBars[position].close - 1))
            }
        }
        if missingForward { warnings.append("Missing next-session bars or suspension: affected code/session observations were skipped.") }
        let maxUniverse = observations.values.map(\.count).max() ?? 0
        guard maxUniverse >= 3 else {
            warnings.append("No IC/stratification was produced because fewer than 3 names had valid observations.")
            return LocalBacktestReport(factor: factor, sampleSessions: sessions, strataCount: 0,
                                       strata: [], icSeries: [], meanIC: nil, icStandardDeviation: nil,
                                       icir: nil, warnings: warnings)
        }
        let strataCount = maxUniverse >= 10 ? 5 : (maxUniverse >= 6 ? 3 : 2)
        if observations.values.contains(where: { !$0.isEmpty && $0.count < strataCount }) {
            warnings.append("Stratification omitted on dates with fewer than \(strataCount) valid names; IC may still be reported for 3+ names.")
        }
        var icPoints = [LocalBacktestICPoint]()
        var returnsByStratum = Array(repeating: [(date: Date, value: Double)](), count: strataCount)
        var observationCounts = Array(repeating: 0, count: strataCount)
        for date in selectedDates {
            guard let rows = observations[date], rows.count >= 3 else { continue }
            let oriented = rows.map { FactorSubset.orient($0.factor, direction: FactorSubset.definitions[factor]!.direction) }
            let factorRanks = Self.ranks(oriented)
            let returnRanks = Self.ranks(rows.map(\.forward))
            let ic = Self.correlation(factorRanks, returnRanks)
            if let ic { icPoints.append(.init(tradeDate: date, value: ic, sampleCount: rows.count)) }
            guard rows.count >= strataCount else { continue }
            let order = rows.indices.sorted { oriented[$0] > oriented[$1] }
            var dailyReturns = Array(repeating: [Double](), count: strataCount)
            for rank in order.indices {
                let bucket = min(strataCount - 1, rank * strataCount / order.count)
                dailyReturns[bucket].append(rows[order[rank]].forward)
            }
            for bucket in 0..<strataCount where !dailyReturns[bucket].isEmpty {
                let dailyMean = dailyReturns[bucket].reduce(0, +) / Double(dailyReturns[bucket].count)
                returnsByStratum[bucket].append((date, dailyMean))
                observationCounts[bucket] += dailyReturns[bucket].count
            }
        }
        let strata = returnsByStratum.enumerated().map { index, values in
            let curve = values.reduce(into: [1.0]) { result, value in result.append(result.last! * (1 + value.value)) }
            let curveDates = values.map { $0.date }
            return LocalBacktestStratum(index: index + 1, sampleCount: observationCounts[index],
                                        averageDailyReturn: values.isEmpty ? nil : values.reduce(0) { $0 + $1.value } / Double(values.count),
                                        cumulativeReturn: values.isEmpty ? nil : curve.last! - 1,
                                        equityCurve: curve, equityCurveDates: curveDates)
        }
        let ics = icPoints.map(\.value)
        let mean = ics.isEmpty ? nil : ics.reduce(0, +) / Double(ics.count)
        let sd = Self.sampleStandardDeviation(ics)
        return LocalBacktestReport(factor: factor, sampleSessions: sessions, strataCount: strataCount,
                                   strata: strata, icSeries: icPoints, meanIC: mean,
                                   icStandardDeviation: sd, icir: Self.informationCoefficientRatio(ics),
                                   warnings: warnings)
    }

    static func informationCoefficientRatio(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        guard let deviation = sampleStandardDeviation(values), deviation > 0 else { return nil }
        return mean / deviation
    }

    static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var result = Array(repeating: 0.0, count: values.count)
        var i = 0
        while i < order.count {
            var j = i + 1
            while j < order.count && values[order[j]] == values[order[i]] { j += 1 }
            let rank = (Double(i + 1) + Double(j)) / 2
            for k in i..<j { result[order[k]] = rank }
            i = j
        }
        return result
    }

    private static func correlation(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 3 else { return nil }
        let xm = x.reduce(0, +) / Double(x.count), ym = y.reduce(0, +) / Double(y.count)
        let numerator = zip(x, y).reduce(0) { $0 + ($1.0 - xm) * ($1.1 - ym) }
        let dx = x.reduce(0) { $0 + ($1 - xm) * ($1 - xm) }
        let dy = y.reduce(0) { $0 + ($1 - ym) * ($1 - ym) }
        guard dx > 0, dy > 0 else { return nil }
        return numerator / sqrt(dx * dy)
    }

    private static func sampleStandardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1))
    }
}

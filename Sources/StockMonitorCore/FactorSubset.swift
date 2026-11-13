import Foundation

public enum FactorID: String, CaseIterable, Codable, Sendable {
    case momentum5 = "momentum_5d"
    case momentum20 = "momentum_20d"
    case momentum60 = "momentum_60d"
    case peTTM = "pe_ttm"
    case pb
    case psTTM = "ps_ttm"
    case dvTTM = "dv_ttm"
    case roe
    case roa
    case grossMargin = "gross_margin"
    case revenueGrowth = "revenue_growth"
    case profitGrowth = "profit_growth"
    case volatility20 = "volatility_20d"
    case volatility60 = "volatility_60d"
    case turnover20 = "turnover_20d"
    case amount20 = "amount_20d"
    case totalMarketValue = "total_mv"
    case maDeviation20 = "ma_deviation_20"
    case rsi14 = "rsi_14"
}

public enum FactorDirection: String, Codable, Sendable {
    case higherIsBetter = "asc"
    case lowerIsBetter = "desc"
}

public struct FactorDefinition: Sendable, Equatable {
    public let id: FactorID
    public let displayName: String
    public let direction: FactorDirection
    public let source: String
    public let requiredFields: [String]

    public init(id: FactorID, displayName: String, direction: FactorDirection,
                source: String, requiredFields: [String]) {
        self.id = id
        self.displayName = displayName
        self.direction = direction
        self.source = source
        self.requiredFields = requiredFields
    }
}

public struct FactorObservation: Sendable, Equatable {
    public let close: Double?
    public let high: Double?
    public let low: Double?
    public let amount: Double?
    public let turnoverRate: Double?
    public let peTTM: Double?
    public let pb: Double?
    public let psTTM: Double?
    public let dvTTM: Double?
    public let totalMarketValue: Double?
    public let roe: Double?
    public let roa: Double?
    public let grossProfitMargin: Double?
    public let revenueYoY: Double?
    public let netProfitYoY: Double?

    public init(close: Double? = nil, high: Double? = nil, low: Double? = nil,
                amount: Double? = nil, turnoverRate: Double? = nil,
                peTTM: Double? = nil, pb: Double? = nil, psTTM: Double? = nil,
                dvTTM: Double? = nil, totalMarketValue: Double? = nil,
                roe: Double? = nil, roa: Double? = nil, grossProfitMargin: Double? = nil,
                revenueYoY: Double? = nil, netProfitYoY: Double? = nil) {
        self.close = close
        self.high = high
        self.low = low
        self.amount = amount
        self.turnoverRate = turnoverRate
        self.peTTM = peTTM
        self.pb = pb
        self.psTTM = psTTM
        self.dvTTM = dvTTM
        self.totalMarketValue = totalMarketValue
        self.roe = roe
        self.roa = roa
        self.grossProfitMargin = grossProfitMargin
        self.revenueYoY = revenueYoY
        self.netProfitYoY = netProfitYoY
    }
}

/// The input observations must be in ascending trade-date order. Daily formulas
/// follow StockAgent's checked-in pandas expressions (including sample std and
/// the amount / 100000 unit conversion).
public enum FactorSubset {
    public static let definitions: [FactorID: FactorDefinition] = [
        .momentum5: .init(id: .momentum5, displayName: "5日动量", direction: .higherIsBetter, source: "daily", requiredFields: ["close"]),
        .momentum20: .init(id: .momentum20, displayName: "20日动量", direction: .higherIsBetter, source: "daily", requiredFields: ["close"]),
        .momentum60: .init(id: .momentum60, displayName: "60日动量", direction: .higherIsBetter, source: "daily", requiredFields: ["close"]),
        .peTTM: .init(id: .peTTM, displayName: "市盈率TTM", direction: .lowerIsBetter, source: "daily_basic", requiredFields: ["pe_ttm"]),
        .pb: .init(id: .pb, displayName: "市净率", direction: .lowerIsBetter, source: "daily_basic", requiredFields: ["pb"]),
        .psTTM: .init(id: .psTTM, displayName: "市销率TTM", direction: .lowerIsBetter, source: "daily_basic", requiredFields: ["ps_ttm"]),
        .dvTTM: .init(id: .dvTTM, displayName: "股息率TTM", direction: .higherIsBetter, source: "daily_basic", requiredFields: ["dv_ttm"]),
        .roe: .init(id: .roe, displayName: "ROE", direction: .higherIsBetter, source: "fina", requiredFields: ["roe"]),
        .roa: .init(id: .roa, displayName: "ROA", direction: .higherIsBetter, source: "fina", requiredFields: ["roa"]),
        .grossMargin: .init(id: .grossMargin, displayName: "毛利率", direction: .higherIsBetter, source: "fina", requiredFields: ["grossprofit_margin"]),
        .revenueGrowth: .init(id: .revenueGrowth, displayName: "营收增长率", direction: .higherIsBetter, source: "fina", requiredFields: ["revenue_yoy"]),
        .profitGrowth: .init(id: .profitGrowth, displayName: "利润增长率", direction: .higherIsBetter, source: "fina", requiredFields: ["netprofit_yoy"]),
        .volatility20: .init(id: .volatility20, displayName: "20日波动率", direction: .lowerIsBetter, source: "daily", requiredFields: ["close"]),
        .volatility60: .init(id: .volatility60, displayName: "60日波动率", direction: .lowerIsBetter, source: "daily", requiredFields: ["close"]),
        .turnover20: .init(id: .turnover20, displayName: "20日换手率", direction: .higherIsBetter, source: "daily_basic", requiredFields: ["turnover_rate"]),
        .amount20: .init(id: .amount20, displayName: "20日成交额", direction: .higherIsBetter, source: "daily", requiredFields: ["amount"]),
        .totalMarketValue: .init(id: .totalMarketValue, displayName: "总市值", direction: .higherIsBetter, source: "daily_basic", requiredFields: ["total_mv"]),
        .maDeviation20: .init(id: .maDeviation20, displayName: "20日均线偏离", direction: .lowerIsBetter, source: "daily", requiredFields: ["close"]),
        .rsi14: .init(id: .rsi14, displayName: "RSI(14)", direction: .higherIsBetter, source: "daily", requiredFields: ["close"])
    ]

    public static func value(for factor: FactorID, observations: [FactorObservation]) -> Double? {
        guard let last = observations.last else { return nil }
        switch factor {
        case .momentum5: return momentum(5, observations)
        case .momentum20: return momentum(20, observations)
        case .momentum60: return momentum(60, observations)
        case .peTTM: return last.peTTM
        case .pb: return last.pb
        case .psTTM: return last.psTTM
        case .dvTTM: return last.dvTTM
        case .roe: return last.roe
        case .roa: return last.roa
        case .grossMargin: return last.grossProfitMargin
        case .revenueGrowth: return last.revenueYoY
        case .profitGrowth: return last.netProfitYoY
        case .volatility20: return volatility(20, observations)
        case .volatility60: return volatility(60, observations)
        case .turnover20: return trailingMean(20, observations.map(\.turnoverRate))
        case .amount20:
            guard let mean = trailingMean(20, observations.map(\.amount)) else { return nil }
            return mean / 100_000
        case .totalMarketValue: return last.totalMarketValue
        case .maDeviation20:
            guard let close = last.close, close > 0,
                  let mean = trailingMean(20, observations.map(\.close)), mean > 0 else { return nil }
            return close / mean - 1
        case .rsi14: return rsi14(observations)
        }
    }

    public static func orient(_ value: Double, direction: FactorDirection) -> Double {
        direction == .lowerIsBetter ? -value : value
    }

    private static func momentum(_ period: Int, _ observations: [FactorObservation]) -> Double? {
        guard observations.count > period,
              let current = observations.last?.close,
              let base = observations[observations.count - period - 1].close,
              base != 0 else { return nil }
        return current / base - 1
    }

    private static func volatility(_ period: Int, _ observations: [FactorObservation]) -> Double? {
        guard observations.count > period else { return nil }
        let closes = observations.suffix(period + 1).compactMap(\.close)
        guard closes.count == period + 1, closes.allSatisfy({ $0 > 0 }) else { return nil }
        var returns: [Double] = []
        for index in 1..<closes.count { returns.append(closes[index] / closes[index - 1] - 1) }
        return sampleStandardDeviation(returns)
    }

    private static func rsi14(_ observations: [FactorObservation]) -> Double? {
        guard observations.count >= 15 else { return nil }
        let closes = observations.suffix(15).compactMap(\.close)
        guard closes.count == 15 else { return nil }
        var gains: [Double] = []
        var losses: [Double] = []
        for index in 1..<closes.count {
            let delta = closes[index] - closes[index - 1]
            gains.append(max(delta, 0))
            losses.append(max(-delta, 0))
        }
        let averageGain = gains.reduce(0, +) / 14
        let averageLoss = losses.reduce(0, +) / 14
        guard averageLoss > 0 else { return nil } // matches upstream zero-to-NaN safe divide
        let rs = averageGain / averageLoss
        return 100 - 100 / (1 + rs)
    }

    private static func trailingMean(_ count: Int, _ values: [Double?]) -> Double? {
        guard values.count >= count else { return nil }
        let trailing = values.suffix(count)
        let concrete = trailing.compactMap { $0 }
        guard concrete.count == count, concrete.allSatisfy(\.isFinite) else { return nil }
        return concrete.reduce(0, +) / Double(count)
    }

    private static func sampleStandardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let sumSquares = values.reduce(0) { $0 + pow($1 - mean, 2) }
        return sqrt(sumSquares / Double(values.count - 1))
    }
}

public enum FactorNormalization {
    /// StockAgent FactorEngine's MAD clipping: median +/- 3 * 1.4826 * MAD.
    public static func winsorizeMAD(_ values: [Double?]) -> [Double?] {
        let finite = values.compactMap { value in value.flatMap { $0.isFinite ? $0 : nil } }.sorted()
        guard !finite.isEmpty else { return values.map { _ in nil } }
        let medianValue = median(finite)
        let mad = median(finite.map { abs($0 - medianValue) }.sorted())
        guard mad > 0 else { return values.map { $0.flatMap { $0.isFinite ? $0 : nil } } }
        let radius = 3 * 1.4826 * mad
        return values.map { value in value.flatMap { $0.isFinite ? min(max($0, medianValue - radius), medianValue + radius) : nil } }
    }

    /// Cross-sectional sample Z-score; zero/one-variance samples become zeros,
    /// matching the source engine's fallback. Missing values stay missing.
    public static func standardizeZScore(_ values: [Double?]) -> [Double?] {
        let finite = values.compactMap { value in value.flatMap { $0.isFinite ? $0 : nil } }
        guard !finite.isEmpty else { return values.map { _ in nil } }
        let mean = finite.reduce(0, +) / Double(finite.count)
        let deviation = sampleStandardDeviation(finite)
        guard let deviation, deviation > 0 else {
            return values.map { $0.flatMap { $0.isFinite ? 0 : nil } }
        }
        return values.map { $0.flatMap { $0.isFinite ? ($0 - mean) / deviation : nil } }
    }

    /// Optional group de-meaning (for example by caller-supplied sector or size
    /// buckets). Upstream StockAgent's checked-in engine does not perform this;
    /// callers must choose exposure groups explicitly.
    public static func neutralizeByGroup(_ values: [Double?], groups: [String?]) -> [Double?] {
        guard values.count == groups.count else { return values.map { _ in nil } }
        var sums: [String: (sum: Double, count: Int)] = [:]
        for index in values.indices {
            let value = values[index]
            let group = groups[index]
            guard let value, value.isFinite, let group else { continue }
            let current = sums[group, default: (0, 0)]
            sums[group] = (current.sum + value, current.count + 1)
        }
        var residuals: [Double?] = []
        for index in values.indices {
            let value = values[index]
            let group = groups[index]
            guard let value, value.isFinite, let group, let aggregate = sums[group], aggregate.count > 0 else {
                residuals.append(nil)
                continue
            }
            residuals.append(value - aggregate.sum / Double(aggregate.count))
        }
        return residuals
    }

    private static func median(_ sorted: [Double]) -> Double {
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) { return (sorted[middle - 1] + sorted[middle]) / 2 }
        return sorted[middle]
    }

    private static func sampleStandardDeviation(_ values: [Double]) -> Double? {
        guard values.count > 1 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        return sqrt(values.reduce(0) { $0 + pow($1 - mean, 2) } / Double(values.count - 1))
    }
}

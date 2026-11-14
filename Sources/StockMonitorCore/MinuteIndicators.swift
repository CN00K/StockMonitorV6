import Foundation

/// An intraday OHLCV-bar estimate. It is not trade-by-trade VWAP or an exchange feed.
public struct VWAPBandValue: Codable, Sendable, Equatable {
    public let vwap: Double
    public let upper: Double
    public let lower: Double
    public let standardDeviation: Double
    public let cumulativeVolume: Double

    public init(vwap: Double, upper: Double, lower: Double,
                standardDeviation: Double, cumulativeVolume: Double) {
        self.vwap = vwap
        self.upper = upper
        self.lower = lower
        self.standardDeviation = standardDeviation
        self.cumulativeVolume = cumulativeVolume
    }
}

/// Minute overloads reuse the tested daily indicator formulae while preserving
/// timestamp order. Each input must be one security's strictly ascending series.
extension StockIndicators {
    private static func dailyProjection(_ bars: [MinuteBar]) -> [DailyBar] {
        bars.map { bar in
            DailyBar(code: bar.code, name: bar.name, tradeDate: bar.timestamp,
                     open: bar.open, high: bar.high, low: bar.low, close: bar.close,
                     volume: bar.volume, amount: bar.amount, sourceID: bar.sourceID,
                     fetchedAt: bar.fetchedAt)
        }
    }

    private static func validDailyInput(_ bars: [DailyBar]) -> Bool {
        guard let first = bars.first else { return true }
        guard !first.code.isEmpty, bars.allSatisfy({
            $0.code == first.code && $0.open.isFinite && $0.high.isFinite &&
            $0.low.isFinite && $0.close.isFinite && $0.volume >= 0
        }) else { return false }
        guard bars.count > 1 else { return true }
        for index in 1..<bars.count where bars[index - 1].tradeDate >= bars[index].tradeDate {
            return false
        }
        return true
    }

    private static func validMinuteInput(_ bars: [MinuteBar]) -> Bool {
        guard let first = bars.first else { return true }
        let code = first.code
        guard !code.isEmpty else { return false }
        guard bars.allSatisfy({ bar in
            bar.code == code && bar.timestamp.timeIntervalSince1970.isFinite &&
            bar.open.isFinite && bar.high.isFinite && bar.low.isFinite && bar.close.isFinite &&
            bar.high >= bar.low && bar.volume >= 0
        }) else { return false }
        guard bars.count > 1 else { return true }
        for index in 1..<bars.count where bars[index - 1].timestamp >= bars[index].timestamp {
            return false
        }
        return true
    }

    public static func macd(_ bars: [MinuteBar], fastPeriod: Int = 12, slowPeriod: Int = 26,
                            signalPeriod: Int = 9) -> [MACDValue?] {
        guard validMinuteInput(bars) else { return [MACDValue?](repeating: nil, count: bars.count) }
        return StockIndicators.macd(dailyProjection(bars), fastPeriod: fastPeriod,
                                    slowPeriod: slowPeriod, signalPeriod: signalPeriod)
    }

    public static func kdj(_ bars: [MinuteBar], period: Int = 9) -> [KDJValue?] {
        guard validMinuteInput(bars) else { return [KDJValue?](repeating: nil, count: bars.count) }
        return StockIndicators.kdj(dailyProjection(bars), period: period)
    }

    public static func bollinger(_ bars: [MinuteBar], period: Int = 20,
                                 multiplier: Double = 2) -> [BollingerValue?] {
        guard validMinuteInput(bars) else { return [BollingerValue?](repeating: nil, count: bars.count) }
        return StockIndicators.bollinger(dailyProjection(bars), period: period, multiplier: multiplier)
    }

    public static func atr(_ bars: [MinuteBar], period: Int = 14) -> [Double?] {
        guard validMinuteInput(bars) else { return [Double?](repeating: nil, count: bars.count) }
        return StockIndicators.atr(dailyProjection(bars), period: period)
    }

    public static func obv(_ bars: [MinuteBar]) -> [Int64?] {
        guard validMinuteInput(bars) else { return [Int64?](repeating: nil, count: bars.count) }
        return StockIndicators.obv(dailyProjection(bars))
    }

    public static func bias(_ bars: [MinuteBar], period: Int = 6) -> [Double?] {
        guard validMinuteInput(bars) else { return [Double?](repeating: nil, count: bars.count) }
        return StockIndicators.bias(dailyProjection(bars), period: period)
    }

    public static func rollingHighLow(_ bars: [MinuteBar], period: Int) -> [HighLowValue?] {
        guard validMinuteInput(bars) else { return [HighLowValue?](repeating: nil, count: bars.count) }
        return StockIndicators.rollingHighLow(dailyProjection(bars), period: period)
    }

    public static func consecutiveUpDown(_ bars: [MinuteBar]) -> [(up: Int, down: Int)?] {
        guard validMinuteInput(bars) else { return [(up: Int, down: Int)?](repeating: nil, count: bars.count) }
        return StockIndicators.consecutiveUpDown(dailyProjection(bars))
    }

    /// Arithmetic-average RSI, matching FactorSubset's existing RSI(14) semantics.
    /// A zero average loss is left unknown to remain consistent with that factor.
    public static func rsi(_ bars: [DailyBar], period: Int = 14) -> [Double?] {
        guard validDailyInput(bars), period > 0 else { return [Double?](repeating: nil, count: bars.count) }
        var result = [Double?](repeating: nil, count: bars.count)
        guard bars.count > period else { return result }
        for index in period..<bars.count {
            let start = index - period
            var gains = 0.0
            var losses = 0.0
            for cursor in (start + 1)...index {
                let change = bars[cursor].close - bars[cursor - 1].close
                gains += max(change, 0)
                losses += max(-change, 0)
            }
            guard losses > 0 else { continue }
            let averageGain = gains / Double(period)
            let averageLoss = losses / Double(period)
            let relativeStrength = averageGain / averageLoss
            let value = 100 - 100 / (1 + relativeStrength)
            result[index] = value.isFinite ? value : nil
        }
        return result
    }

    public static func rsi(_ bars: [MinuteBar], period: Int = 14) -> [Double?] {
        guard validMinuteInput(bars) else { return [Double?](repeating: nil, count: bars.count) }
        return rsi(dailyProjection(bars), period: period)
    }

    /// Cumulative, per-A-share-trading-day OHLCV-bar weighted VWAP and ±sigma band.
    /// Typical price (high + low + close)/3 is weighted by each supplied bar's
    /// volume; this is an approximation, not a reconstruction of individual trades.
    public static func vwapBands(_ bars: [MinuteBar], sigmaMultiplier: Double = 1)
        -> [VWAPBandValue?] {
        guard validMinuteInput(bars), sigmaMultiplier.isFinite, sigmaMultiplier >= 0 else {
            return [VWAPBandValue?](repeating: nil, count: bars.count)
        }
        guard !bars.isEmpty else { return [] }
        let calendar = Calendar(identifier: .gregorian)
        var result = [VWAPBandValue?](repeating: nil, count: bars.count)
        var activeDay: String?
        var totalWeight = 0.0
        var mean = 0.0
        var sumSquaredDeviations = 0.0

        for index in bars.indices {
            let bar = bars[index]
            let parts = calendar.dateComponents(in: MarketClock.timeZone, from: bar.timestamp)
            let dayKey = "\(parts.year ?? 0)-\(parts.month ?? 0)-\(parts.day ?? 0)"
            if dayKey != activeDay {
                activeDay = dayKey
                totalWeight = 0
                mean = 0
                sumSquaredDeviations = 0
            }

            let weight = Double(bar.volume)
            let typicalPrice = (bar.high + bar.low + bar.close) / 3
            guard typicalPrice.isFinite else { return [VWAPBandValue?](repeating: nil, count: bars.count) }
            if weight > 0 {
                let nextWeight = totalWeight + weight
                let delta = typicalPrice - mean
                let nextMean = mean + (weight / nextWeight) * delta
                sumSquaredDeviations += weight * delta * (typicalPrice - nextMean)
                totalWeight = nextWeight
                mean = nextMean
                guard totalWeight.isFinite, mean.isFinite, sumSquaredDeviations.isFinite else {
                    return [VWAPBandValue?](repeating: nil, count: bars.count)
                }
            }
            guard totalWeight > 0 else { continue }
            let deviation = sqrt(max(0, sumSquaredDeviations / totalWeight))
            let upper = mean + sigmaMultiplier * deviation
            let lower = mean - sigmaMultiplier * deviation
            guard deviation.isFinite, upper.isFinite, lower.isFinite else {
                return [VWAPBandValue?](repeating: nil, count: bars.count)
            }
            result[index] = VWAPBandValue(vwap: mean, upper: upper, lower: lower,
                standardDeviation: deviation, cumulativeVolume: totalWeight)
        }
        return result
    }
}

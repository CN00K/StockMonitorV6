import Foundation

/// A MACD observation. The MACD line becomes available after the slow EMA seed;
/// signal and histogram remain nil until enough MACD values exist.
public struct MACDValue: Equatable, Sendable {
    public let macd: Double
    public let signal: Double?
    public let histogram: Double?

    public init(macd: Double, signal: Double? = nil, histogram: Double? = nil) {
        self.macd = macd
        self.signal = signal
        self.histogram = histogram
    }
}

public struct KDJValue: Equatable, Sendable {
    public let k: Double
    public let d: Double
    public let j: Double
    public init(k: Double, d: Double, j: Double) { self.k = k; self.d = d; self.j = j }
}

public struct BollingerValue: Equatable, Sendable {
    public let middle: Double
    public let upper: Double
    public let lower: Double
    public init(middle: Double, upper: Double, lower: Double) {
        self.middle = middle; self.upper = upper; self.lower = lower
    }
}

public struct ATRValue: Equatable, Sendable {
    public let trueRange: Double
    public let atr: Double
    public init(trueRange: Double, atr: Double?) { self.trueRange = trueRange; self.atr = atr ?? .nan }
}

public struct HighLowValue: Equatable, Sendable {
    public let high: Double
    public let low: Double
    public init(high: Double, low: Double) { self.high = high; self.low = low }
}

/// Scalar, pure daily indicators. Inputs must be strictly ascending by unique
/// `tradeDate` and have finite OHLC values. Invalid input returns an aligned
/// array of nils (and therefore never fabricates a result). Empty input returns
/// an empty array. Volume is Int64 and is accepted as supplied, including zero.
public enum StockIndicators {
    private static func valid(_ bars: [DailyBar]) -> Bool {
        guard bars.allSatisfy({ $0.open.isFinite && $0.high.isFinite && $0.low.isFinite && $0.close.isFinite && $0.volume >= 0 }) else { return false }
        guard bars.count > 1 else { return true }
        for i in 1..<bars.count where bars[i - 1].tradeDate >= bars[i].tradeDate { return false }
        return true
    }

    private static func validPeriod(_ period: Int) -> Bool { period > 0 }
    private static func nils<T>(_ count: Int) -> [T?] { Array(repeating: nil, count: count) }

    /// EMA uses an SMA seed: the first value is the average of the first period
    /// samples, followed by `alpha = 2 / (period + 1)` recursive updates.
    private static func ema(_ values: [Double], period: Int) -> [Double?] {
        guard validPeriod(period), values.count >= period else { return nils(values.count) }
        var result: [Double?] = nils(values.count)
        var seed = values.prefix(period).reduce(0, +) / Double(period)
        result[period - 1] = seed
        let alpha = 2.0 / Double(period + 1)
        if values.count > period {
            for index in period..<values.count {
                seed = alpha * values[index] + (1 - alpha) * seed
                result[index] = seed
            }
        }
        return result
    }

    /// MACD = fast EMA - slow EMA; signal is an EMA of MACD values, also with
    /// an SMA seed. All returned positions align with `bars`.
    public static func macd(_ bars: [DailyBar], fastPeriod: Int = 12, slowPeriod: Int = 26,
                            signalPeriod: Int = 9) -> [MACDValue?] {
        guard valid(bars), validPeriod(fastPeriod), validPeriod(slowPeriod), validPeriod(signalPeriod), fastPeriod <= slowPeriod else { return nils(bars.count) }
        let closes = bars.map(\.close), fast = ema(closes, period: fastPeriod), slow = ema(closes, period: slowPeriod)
        var lines: [Double?] = nils(bars.count)
        var result: [MACDValue?] = nils(bars.count)
        for i in bars.indices where fast[i] != nil && slow[i] != nil { lines[i] = fast[i]! - slow[i]! }
        let lineValues = lines.compactMap { $0 }
        let signals = ema(lineValues, period: signalPeriod)
        var signalIndex = 0
        for i in bars.indices where lines[i] != nil {
            let line = lines[i]!
            if let signal = signals[signalIndex] { result[i] = MACDValue(macd: line, signal: signal, histogram: line - signal) }
            else { result[i] = MACDValue(macd: line) }
            signalIndex += 1
        }
        return result
    }

    /// KDJ uses the inclusive rolling high/low over `period`, an RSV of 50 when
    /// high equals low, and the conventional recursive K/D smoothing of 1/3.
    public static func kdj(_ bars: [DailyBar], period: Int = 9) -> [KDJValue?] {
        guard valid(bars), validPeriod(period) else { return nils(bars.count) }
        var result: [KDJValue?] = nils(bars.count), k = 50.0, d = 50.0
        for i in bars.indices where i + 1 >= period {
            let window = bars[(i + 1 - period)...i], high = window.map(\.high).max()!, low = window.map(\.low).min()!
            let rsv = high == low ? 50.0 : (bars[i].close - low) / (high - low) * 100
            k = (2 * k + rsv) / 3; d = (2 * d + k) / 3
            result[i] = KDJValue(k: k, d: d, j: 3 * k - 2 * d)
        }
        return result
    }

    /// Bollinger bands use the rolling population standard deviation (divide by N).
    public static func bollinger(_ bars: [DailyBar], period: Int = 20, multiplier: Double = 2) -> [BollingerValue?] {
        guard valid(bars), validPeriod(period), multiplier.isFinite else { return nils(bars.count) }
        var result: [BollingerValue?] = nils(bars.count)
        for i in bars.indices where i + 1 >= period {
            let values = bars[(i + 1 - period)...i].map(\.close), mean = values.reduce(0, +) / Double(period)
            let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(period), deviation = sqrt(variance)
            result[i] = BollingerValue(middle: mean, upper: mean + multiplier * deviation, lower: mean - multiplier * deviation)
        }
        return result
    }

    /// ATR uses true range max(high-low, abs(high-previous close), abs(low-previous close)).
    /// Wilder's ATR is seeded by the SMA of the first `period` true ranges (the
    /// first bar uses high-low), then smoothed as ((previous * (N-1)) + TR) / N.
    public static func atr(_ bars: [DailyBar], period: Int = 14) -> [Double?] {
        guard valid(bars), validPeriod(period) else { return nils(bars.count) }
        var ranges = [Double](), result: [Double?] = nils(bars.count), previousClose: Double?
        for bar in bars {
            let tr = previousClose.map { max(bar.high - bar.low, max(abs(bar.high - $0), abs(bar.low - $0))) } ?? (bar.high - bar.low)
            ranges.append(tr); previousClose = bar.close
        }
        guard ranges.count >= period else { return result }
        var value = ranges.prefix(period).reduce(0, +) / Double(period); result[period - 1] = value
        if ranges.count > period { for i in period..<ranges.count { value = (value * Double(period - 1) + ranges[i]) / Double(period); result[i] = value } }
        return result
    }

    /// OBV starts at zero. Equal closes leave it unchanged; ties are not treated as up days.
    public static func obv(_ bars: [DailyBar]) -> [Int64?] {
        guard valid(bars) else { return nils(bars.count) }
        var result = [Int64?](repeating: nil, count: bars.count), total: Int64 = 0
        for i in bars.indices { if i > 0 { if bars[i].close > bars[i - 1].close { total += bars[i].volume } else if bars[i].close < bars[i - 1].close { total -= bars[i].volume } }; result[i] = total }
        return result
    }

    /// BIAS is `(close - SMA(period)) / SMA(period) * 100`; a zero SMA yields nil.
    public static func bias(_ bars: [DailyBar], period: Int = 6) -> [Double?] {
        guard valid(bars), validPeriod(period) else { return nils(bars.count) }
        var result: [Double?] = nils(bars.count)
        for i in bars.indices where i + 1 >= period { let mean = bars[(i + 1 - period)...i].map(\.close).reduce(0, +) / Double(period); if mean != 0 { result[i] = (bars[i].close - mean) / mean * 100 } }
        return result
    }

    /// Rolling windows are inclusive. Equal extrema resolve to that same value.
    public static func rollingHighLow(_ bars: [DailyBar], period: Int) -> [HighLowValue?] {
        guard valid(bars), validPeriod(period) else { return nils(bars.count) }
        var result: [HighLowValue?] = nils(bars.count)
        for i in bars.indices where i + 1 >= period { let window = bars[(i + 1 - period)...i]; result[i] = HighLowValue(high: window.map(\.high).max()!, low: window.map(\.low).min()!) }
        return result
    }

    /// Counts consecutive strict close increases/decreases ending at each bar.
    /// A flat close resets both counters to zero; the first bar is (0, 0).
    public static func consecutiveUpDown(_ bars: [DailyBar]) -> [(up: Int, down: Int)?] {
        guard valid(bars) else { return nils(bars.count) }
        var result = [(up: Int, down: Int)?](repeating: nil, count: bars.count), up = 0, down = 0
        for i in bars.indices { if i == 0 { up = 0; down = 0 } else if bars[i].close > bars[i - 1].close { up += 1; down = 0 } else if bars[i].close < bars[i - 1].close { down += 1; up = 0 } else { up = 0; down = 0 }; result[i] = (up, down) }
        return result
    }
}

// Convenience free functions keep call sites lightweight while retaining one implementation.
public func macd(_ bars: [DailyBar], fastPeriod: Int = 12, slowPeriod: Int = 26, signalPeriod: Int = 9) -> [MACDValue?] { StockIndicators.macd(bars, fastPeriod: fastPeriod, slowPeriod: slowPeriod, signalPeriod: signalPeriod) }
public func kdj(_ bars: [DailyBar], period: Int = 9) -> [KDJValue?] { StockIndicators.kdj(bars, period: period) }
public func bollingerBands(_ bars: [DailyBar], period: Int = 20, multiplier: Double = 2) -> [BollingerValue?] { StockIndicators.bollinger(bars, period: period, multiplier: multiplier) }
public func atr(_ bars: [DailyBar], period: Int = 14) -> [Double?] { StockIndicators.atr(bars, period: period) }
public func obv(_ bars: [DailyBar]) -> [Int64?] { StockIndicators.obv(bars) }
public func bias(_ bars: [DailyBar], period: Int = 6) -> [Double?] { StockIndicators.bias(bars, period: period) }
public func rollingHighLow(_ bars: [DailyBar], period: Int) -> [HighLowValue?] { StockIndicators.rollingHighLow(bars, period: period) }
public func consecutiveUpDown(_ bars: [DailyBar]) -> [(up: Int, down: Int)?] { StockIndicators.consecutiveUpDown(bars) }

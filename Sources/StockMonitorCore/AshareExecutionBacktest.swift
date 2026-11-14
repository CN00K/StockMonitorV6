import Foundation

/// The direction of an A-share execution run. A run has one explicit side; no
/// broker commission or side-specific policy is inferred by this module.
public enum AshareExecutionSide: String, Codable, Sendable, Equatable {
    case buy
    case sell
}

/// Explicit assumptions for one deterministic daily-bar execution run.
public struct AshareExecutionConfig: Codable, Sendable, Equatable {
    public let commissionRate: Double
    public let minimumCommission: Double
    public let stampDutyRate: Double
    public let slippageRate: Double
    public let tickSize: Double
    public let lotSize: Int
    public let side: AshareExecutionSide
    public let initialCash: Double

    public init(commissionRate: Double, minimumCommission: Double,
                stampDutyRate: Double, slippageRate: Double,
                tickSize: Double, lotSize: Int,
                side: AshareExecutionSide, initialCash: Double = 0) {
        self.commissionRate = commissionRate
        self.minimumCommission = minimumCommission
        self.stampDutyRate = stampDutyRate
        self.slippageRate = slippageRate
        self.tickSize = tickSize
        self.lotSize = lotSize
        self.side = side
        self.initialCash = initialCash
    }

    public var validationErrors: [String] {
        var errors: [String] = []
        if !commissionRate.isFinite || commissionRate < 0 { errors.append("commissionRate must be finite and non-negative.") }
        if !minimumCommission.isFinite || minimumCommission < 0 { errors.append("minimumCommission must be finite and non-negative.") }
        if !stampDutyRate.isFinite || stampDutyRate < 0 { errors.append("stampDutyRate must be finite and non-negative.") }
        if !slippageRate.isFinite || slippageRate < 0 { errors.append("slippageRate must be finite and non-negative.") }
        if !tickSize.isFinite || tickSize <= 0 { errors.append("tickSize must be finite and greater than zero.") }
        if lotSize <= 0 { errors.append("lotSize must be greater than zero.") }
        if !initialCash.isFinite || initialCash < 0 { errors.append("initialCash must be finite and non-negative.") }
        return errors
    }
}

/// A signal placed after `signalDate`; it can only execute on that security's
/// next represented trading session. Quantity is rounded down to whole lots.
public struct AshareExecutionOrder: Codable, Sendable, Equatable {
    public let code: String
    public let signalDate: Date
    public let quantity: Int
    public init(code: String, signalDate: Date, quantity: Int) {
        self.code = code; self.signalDate = signalDate; self.quantity = quantity
    }
}

/// An explicitly supplied daily price-limit pair. Limits are never inferred.
public struct AsharePriceLimit: Codable, Sendable, Equatable {
    public let code: String
    public let tradeDate: Date
    public let lower: Double
    public let upper: Double
    public init(code: String, tradeDate: Date, lower: Double, upper: Double) {
        self.code = code; self.tradeDate = tradeDate; self.lower = lower; self.upper = upper
    }
    fileprivate var isValid: Bool { lower.isFinite && upper.isFinite && lower >= 0 && upper >= lower }
}

public enum AshareExecutionSkipReason: String, Codable, Sendable, Equatable {
    case invalidConfig
    case invalidOrder
    case missingNextSessionBar
    case inconsistentOrAdjustedBar
    case invalidBar
    case quantityBelowLot
    case insufficientCash
    case insufficientT1Inventory
    case priceLimitTouch
}

public struct AshareExecutionEvent: Codable, Sendable, Equatable {
    public let order: AshareExecutionOrder
    public let executionDate: Date?
    public let filledQuantity: Int
    public let roundedPrice: Double?
    public let commission: Double
    public let stampDuty: Double
    public let slippage: Double
    public let reason: AshareExecutionSkipReason?
    public var filled: Bool { filledQuantity > 0 && reason == nil }

    public init(order: AshareExecutionOrder, executionDate: Date?, filledQuantity: Int,
                roundedPrice: Double?, commission: Double, stampDuty: Double,
                slippage: Double, reason: AshareExecutionSkipReason?) {
        self.order = order; self.executionDate = executionDate; self.filledQuantity = filledQuantity
        self.roundedPrice = roundedPrice; self.commission = commission; self.stampDuty = stampDuty
        self.slippage = slippage; self.reason = reason
    }
}

public struct AshareExecutionBacktestReport: Codable, Sendable, Equatable {
    public let events: [AshareExecutionEvent]
    public let validCount: Int
    public let skippedCount: Int
    public let finalCash: Double
    public let holdings: [String: Int]
    public let warnings: [String]

    public init(events: [AshareExecutionEvent], validCount: Int, skippedCount: Int,
                finalCash: Double, holdings: [String: Int], warnings: [String]) {
        self.events = events; self.validCount = validCount; self.skippedCount = skippedCount
        self.finalCash = finalCash; self.holdings = holdings; self.warnings = warnings
    }
}

/// Pure, deterministic daily-bar execution simulation. It intentionally has no
/// intraday liquidity or queue evidence: a daily OHLC bar cannot establish either.
public enum AshareExecutionBacktest {
    public static func run(bars: [DailyBar], orders: [AshareExecutionOrder],
                           priceLimits: [AsharePriceLimit] = [],
                           config: AshareExecutionConfig) -> AshareExecutionBacktestReport {
        let validation = config.validationErrors
        guard validation.isEmpty else {
            let events = orders.map { AshareExecutionEvent(order: $0, executionDate: nil, filledQuantity: 0,
                roundedPrice: nil, commission: 0, stampDuty: 0, slippage: 0, reason: .invalidConfig) }
            return AshareExecutionBacktestReport(events: events, validCount: 0, skippedCount: events.count,
                finalCash: config.initialCash, holdings: [:], warnings: validation)
        }
        let dates = Set(bars.map(\.tradeDate)).sorted()
        let grouped = Dictionary(grouping: bars, by: \.code).mapValues { $0.sorted { $0.tradeDate < $1.tradeDate } }
        let limits = Dictionary(uniqueKeysWithValues: priceLimits.filter(\.isValid).map { ("\($0.code)|\($0.tradeDate.timeIntervalSinceReferenceDate)", $0) })
        var cash = config.initialCash
        var holdings: [String: Int] = [:]
        var availableDate: [String: Date] = [:]
        var events: [AshareExecutionEvent] = []
        let sortedOrders = orders.enumerated().sorted {
            if $0.element.signalDate != $1.element.signalDate { return $0.element.signalDate < $1.element.signalDate }
            if $0.element.code != $1.element.code { return $0.element.code < $1.element.code }
            return $0.offset < $1.offset
        }.map(\.element)

        for order in sortedOrders {
            guard !order.code.isEmpty, order.quantity > 0 else {
                events.append(.init(order: order, executionDate: nil, filledQuantity: 0, roundedPrice: nil, commission: 0, stampDuty: 0, slippage: 0, reason: .invalidOrder)); continue
            }
            let nextDate = dates.first { $0 > order.signalDate }
            guard let executionDate = nextDate, let bar = grouped[order.code]?.first(where: { $0.tradeDate == executionDate }) else {
                events.append(.init(order: order, executionDate: nextDate, filledQuantity: 0, roundedPrice: nil, commission: 0, stampDuty: 0, slippage: 0, reason: .missingNextSessionBar)); continue
            }
            guard bar.priceAdjustment == "none" else {
                events.append(.init(order: order, executionDate: executionDate, filledQuantity: 0, roundedPrice: nil, commission: 0, stampDuty: 0, slippage: 0, reason: .inconsistentOrAdjustedBar)); continue
            }
            guard [bar.open, bar.high, bar.low, bar.close].allSatisfy({ $0.isFinite && $0 > 0 }),
                  bar.high >= max(bar.open, bar.close), bar.low <= min(bar.open, bar.close),
                  bar.high >= bar.low else {
                events.append(.init(order: order, executionDate: executionDate, filledQuantity: 0, roundedPrice: nil, commission: 0, stampDuty: 0, slippage: 0, reason: .invalidBar)); continue
            }
            let quantity = (order.quantity / config.lotSize) * config.lotSize
            guard quantity > 0 else {
                events.append(.init(order: order, executionDate: executionDate, filledQuantity: 0, roundedPrice: nil, commission: 0, stampDuty: 0, slippage: 0, reason: .quantityBelowLot)); continue
            }
            let key = "\(order.code)|\(executionDate.timeIntervalSinceReferenceDate)"
            // Conservative daily-bar proxy: if the bar touched the adverse limit,
            // the model cannot prove a fill through the queue and skips the order.
            if let limit = limits[key], (config.side == .buy && bar.high >= limit.upper) || (config.side == .sell && bar.low <= limit.lower) {
                events.append(.init(order: order, executionDate: executionDate, filledQuantity: 0, roundedPrice: nil, commission: 0, stampDuty: 0, slippage: 0, reason: .priceLimitTouch)); continue
            }
            if config.side == .sell && (holdings[order.code, default: 0] < quantity || availableDate[order.code].map({ $0 >= executionDate }) == true) {
                events.append(.init(order: order, executionDate: executionDate, filledQuantity: 0, roundedPrice: nil, commission: 0, stampDuty: 0, slippage: 0, reason: .insufficientT1Inventory)); continue
            }
            let direction = config.side == .buy ? 1.0 : -1.0
            let rawPrice = bar.open * (1 + direction * config.slippageRate)
            let price = Self.roundToTick(rawPrice, tick: config.tickSize)
            let notional = price * Double(quantity)
            let commission = max(notional * config.commissionRate, config.minimumCommission)
            let duty = config.side == .sell ? notional * config.stampDutyRate : 0
            let total = config.side == .buy ? notional + commission : notional - commission - duty
            guard config.side == .sell || cash >= total else {
                events.append(.init(order: order, executionDate: executionDate, filledQuantity: 0, roundedPrice: price, commission: commission, stampDuty: duty, slippage: abs(price - bar.open) * Double(quantity), reason: .insufficientCash)); continue
            }
            if config.side == .buy { cash -= total; holdings[order.code, default: 0] += quantity; availableDate[order.code] = executionDate }
            else { cash += total; holdings[order.code, default: 0] -= quantity }
            events.append(.init(order: order, executionDate: executionDate, filledQuantity: quantity, roundedPrice: price,
                commission: commission, stampDuty: duty, slippage: abs(price - bar.open) * Double(quantity), reason: nil))
        }
        return AshareExecutionBacktestReport(events: events, validCount: events.filter(\.filled).count,
            skippedCount: events.filter { !$0.filled }.count, finalCash: cash, holdings: holdings,
            warnings: ["Daily OHLC bars provide no intraday liquidity or queue-position evidence; fills are not proof of executable size or priority.", "Only explicitly supplied price-limit pairs are used; limits are never inferred.", "Adjusted, inconsistent, or missing bars are skipped; no forward fill is applied."])
    }

    public static func roundToTick(_ value: Double, tick: Double) -> Double {
        guard value.isFinite, tick.isFinite, tick > 0 else { return .nan }
        return (value / tick).rounded(.toNearestOrAwayFromZero) * tick
    }
}

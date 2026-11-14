import Foundation

/// Explicit data-availability declarations for the optional execution overlay.
/// Missing inputs are warnings, never silently reconstructed data.
public struct LocalBacktestExecutionDataAvailability: Codable, Sendable, Equatable {
    public let constituentMembership: Bool
    public let corporateActions: Bool
    public let priceLimits: Bool

    public init(constituentMembership: Bool = false,
                corporateActions: Bool = false,
                priceLimits: Bool = false) {
        self.constituentMembership = constituentMembership
        self.corporateActions = corporateActions
        self.priceLimits = priceLimits
    }
}

/// Configuration for the opt-in execution overlay. The gross factor statistics
/// are always calculated by LocalBacktest; this configuration only adds a
/// conservative, executable-order simulation.
public struct LocalBacktestExecutionConfig: Codable, Sendable, Equatable {
    public let execution: AshareExecutionConfig
    public let quantityPerSignal: Int
    public let topN: Int
    public let priceLimits: [AsharePriceLimit]
    public let dataAvailability: LocalBacktestExecutionDataAvailability

    public init(execution: AshareExecutionConfig,
                quantityPerSignal: Int = 100,
                topN: Int = 1,
                priceLimits: [AsharePriceLimit] = [],
                dataAvailability: LocalBacktestExecutionDataAvailability = .init()) {
        self.execution = execution
        self.quantityPerSignal = quantityPerSignal
        self.topN = topN
        self.priceLimits = priceLimits
        self.dataAvailability = dataAvailability
    }

    fileprivate var validationErrors: [String] {
        var errors = execution.validationErrors
        if quantityPerSignal <= 0 { errors.append("quantityPerSignal must be greater than zero.") }
        if topN <= 0 { errors.append("topN must be greater than zero.") }
        return errors
    }
}

/// Result of joining the gross local factor analysis to the existing execution
/// simulator. `gross` is untouched by execution assumptions.
public struct LocalBacktestExecutionReport: Codable, Sendable, Equatable {
    public let gross: LocalBacktestReport
    public let execution: AshareExecutionBacktestReport
    public let netEquityCurve: [Double]
    public let netEquityCurveDates: [Date]
    public let warnings: [String]

    public init(gross: LocalBacktestReport,
                execution: AshareExecutionBacktestReport,
                netEquityCurve: [Double],
                netEquityCurveDates: [Date],
                warnings: [String]) {
        self.gross = gross
        self.execution = execution
        self.netEquityCurve = netEquityCurve
        self.netEquityCurveDates = netEquityCurveDates
        self.warnings = warnings
    }
}

public extension LocalBacktest {
    /// Runs the unchanged gross IC/stratification analysis and, when `execution`
    /// is supplied, overlays factor-selected orders on AshareExecutionBacktest.
    /// No execution overlay is performed unless the caller opts in explicitly.
    static func run(bars: [DailyBar], factor: FactorID, sampleSessions: Int = 20,
                    execution: LocalBacktestExecutionConfig) -> LocalBacktestExecutionReport {
        let gross = Self.run(bars: bars, factor: factor, sampleSessions: sampleSessions)
        let validation = execution.validationErrors
        var warnings = gross.warnings
        warnings += [
            "Execution overlay is opt-in; gross IC and stratification metrics are not netted.",
            "Orders use only factor observations and represented daily bars; no fills are fabricated."
        ]
        if !execution.dataAvailability.constituentMembership {
            warnings.append("Constituent membership data is missing; the supplied bar universe is used without survivorship correction.")
        }
        if !execution.dataAvailability.corporateActions {
            warnings.append("Corporate-action data is missing; adjusted bars and inferred splits/dividends are not used.")
        }
        if !execution.dataAvailability.priceLimits || execution.priceLimits.isEmpty {
            warnings.append("Price-limit data is missing or empty; limit-touch no-fill can only be applied where explicit limits are supplied.")
        }

        guard validation.isEmpty else {
            let empty = AshareExecutionBacktest.run(bars: bars, orders: [], priceLimits: execution.priceLimits,
                                                     config: execution.execution)
            warnings += validation
            return LocalBacktestExecutionReport(gross: gross, execution: empty,
                                                netEquityCurve: [execution.execution.initialCash],
                                                netEquityCurveDates: [], warnings: warnings)
        }

        let cleanBars = bars.filter { $0.priceAdjustment == "none" }
        let grouped = Dictionary(grouping: cleanBars, by: \.code)
            .mapValues { $0.sorted { $0.tradeDate < $1.tradeDate } }
        let dates = Set(cleanBars.map(\.tradeDate)).sorted()
        let sessions = max(0, sampleSessions)
        let selectedDates = sessions == 0 ? [] : Array(dates.suffix(sessions + 1))
        var orders: [AshareExecutionOrder] = []
        var bridgeWarnings: [String] = []
        let definition = FactorSubset.definitions[factor]

        if let definition {
            for date in selectedDates.dropLast() {
                var candidates: [(code: String, score: Double)] = []
                for (code, codeBars) in grouped.sorted(by: { $0.key < $1.key }) {
                    guard let position = codeBars.firstIndex(where: { $0.tradeDate == date }),
                          dates.contains(where: { $0 > date }),
                          codeBars.contains(where: { $0.tradeDate == dates.first(where: { $0 > date })! }) else {
                        continue
                    }
                    let observations = codeBars[...position].map {
                        FactorObservation(close: $0.close, high: $0.high, low: $0.low,
                                          amount: $0.amount, turnoverRate: $0.turnoverRate)
                    }
                    guard let value = FactorSubset.value(for: factor, observations: observations), value.isFinite else { continue }
                    candidates.append((code, FactorSubset.orient(value, direction: definition.direction)))
                }
                let selected = candidates.sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.code < $1.code
                }.prefix(execution.topN)
                orders += selected.map {
                    AshareExecutionOrder(code: $0.code, signalDate: date, quantity: execution.quantityPerSignal)
                }
            }
        } else {
            bridgeWarnings.append("Factor \(factor.rawValue) is unavailable; no execution orders were generated.")
        }

        let simulated = AshareExecutionBacktest.run(bars: cleanBars, orders: orders,
                                                     priceLimits: execution.priceLimits,
                                                     config: execution.execution)
        warnings += bridgeWarnings
        warnings += simulated.warnings
        let curveDates = dates.filter { $0 >= (selectedDates.first ?? .distantFuture) }
        var curve: [Double] = []
        for date in curveDates {
            let cashAtDate = simulated.events.filter { $0.filled && ($0.executionDate ?? .distantFuture) <= date }
                .reduce(execution.execution.initialCash) { cash, event in
                    let notional = (event.roundedPrice ?? 0) * Double(event.filledQuantity)
                    let total = notional + event.commission + event.stampDuty
                    return execution.execution.side == .buy ? cash - total : cash + notional - event.commission - event.stampDuty
                }
            var holdings: [String: Int] = [:]
            for event in simulated.events where event.filled && (event.executionDate ?? .distantFuture) <= date {
                holdings[event.order.code, default: 0] += execution.execution.side == .buy ? event.filledQuantity : -event.filledQuantity
            }
            let marked = holdings.reduce(0.0) { total, holding in
                total + Double(holding.value) * (grouped[holding.key]?.last(where: { $0.tradeDate == date })?.close ?? 0)
            }
            curve.append(cashAtDate + marked)
        }
        return LocalBacktestExecutionReport(gross: gross, execution: simulated,
                                            netEquityCurve: curve,
                                            netEquityCurveDates: curveDates,
                                            warnings: warnings)
    }

    func run(bars: [DailyBar], factor: FactorID, sampleSessions: Int = 20,
             execution: LocalBacktestExecutionConfig) -> LocalBacktestExecutionReport {
        Self.run(bars: bars, factor: factor, sampleSessions: sampleSessions, execution: execution)
    }
}

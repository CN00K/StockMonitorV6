import Foundation

public struct LocalCorrelationMatrix: Sendable, Equatable {
    public let seriesIDs: [String]
    public let coefficients: [[Double?]]
    public let observationCounts: [[Int]]
    public let minimumObservations: Int
    public let warnings: [String]

    public init(seriesIDs: [String], coefficients: [[Double?]], observationCounts: [[Int]],
                minimumObservations: Int, warnings: [String]) {
        self.seriesIDs = seriesIDs
        self.coefficients = coefficients
        self.observationCounts = observationCounts
        self.minimumObservations = minimumObservations
        self.warnings = warnings
    }
}

/// Local Pearson correlation utilities. Missing dates are pairwise excluded;
/// insufficient or zero-variance samples remain nil rather than being displayed as 0.
public enum LocalCorrelationAnalyzer {
    public static func matrix(series: [String: [Date: Double]], minimumObservations: Int = 20,
                              warnings: [String] = []) -> LocalCorrelationMatrix {
        let ids = series.keys.filter { !$0.isEmpty }.sorted()
        let minimum = max(2, minimumObservations)
        var coefficients = Array(repeating: Array<Double?>(repeating: nil, count: ids.count), count: ids.count)
        var observationCounts = Array(repeating: Array(repeating: 0, count: ids.count), count: ids.count)

        for row in ids.indices {
            let left = finiteSeries(series[ids[row]] ?? [:])
            for column in row..<ids.count {
                let right = finiteSeries(series[ids[column]] ?? [:])
                let dates = Set(left.keys).intersection(right.keys).sorted()
                let pairs = dates.compactMap { date -> (Double, Double)? in
                    guard let x = left[date], let y = right[date] else { return nil }
                    return (x, y)
                }
                observationCounts[row][column] = pairs.count
                observationCounts[column][row] = pairs.count
                guard pairs.count >= minimum, let coefficient = pearson(pairs) else { continue }
                coefficients[row][column] = coefficient
                coefficients[column][row] = coefficient
            }
        }

        return LocalCorrelationMatrix(seriesIDs: ids, coefficients: coefficients,
            observationCounts: observationCounts, minimumObservations: minimum, warnings: warnings)
    }

    /// Builds close-to-close returns aligned to adjacent sessions present in the
    /// supplied universe. Only explicitly unadjusted (`priceAdjustment == "none"`)
    /// daily bars are used; corporate actions can therefore distort correlations.
    public static func returnMatrix(bars: [DailyBar], minimumObservations: Int = 20) -> LocalCorrelationMatrix {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = MarketClock.timeZone
        var rows: [String: [Date: [DailyBar]]] = [:]
        for bar in bars where !bar.code.isEmpty && bar.priceAdjustment == "none" {
            guard bar.close.isFinite, bar.close > 0 else { continue }
            let session = calendar.startOfDay(for: bar.tradeDate)
            rows[bar.code, default: [:]][session, default: []].append(bar)
        }

        var closeByCode: [String: [Date: Double]] = [:]
        for (code, sessions) in rows {
            var closes: [Date: Double] = [:]
            for (date, values) in sessions where values.count == 1 {
                closes[date] = values[0].close
            }
            if !closes.isEmpty { closeByCode[code] = closes }
        }
        let allSessions = Set(closeByCode.values.flatMap { $0.keys }).sorted()
        var returnSeries: [String: [Date: Double]] = [:]
        if allSessions.count > 1 {
            for (code, closes) in closeByCode {
                var values: [Date: Double] = [:]
                for index in 1..<allSessions.count {
                    let previousDate = allSessions[index - 1]
                    let currentDate = allSessions[index]
                    guard let previous = closes[previousDate], let current = closes[currentDate] else { continue }
                    let change = current / previous - 1
                    if change.isFinite { values[currentDate] = change }
                }
                returnSeries[code] = values
            }
        } else {
            returnSeries = Dictionary(uniqueKeysWithValues: closeByCode.keys.map { ($0, [:]) })
        }

        var warnings = ["Returns use unadjusted close prices; splits, dividends, suspensions, and survivorship can distort the matrix."]
        if rows.values.contains(where: { $0.values.contains(where: { $0.count > 1 }) }) {
            warnings.append("Duplicate code/session bars were excluded rather than selecting an arbitrary close.")
        }
        return matrix(series: returnSeries, minimumObservations: minimumObservations, warnings: warnings)
    }

    private static func finiteSeries(_ series: [Date: Double]) -> [Date: Double] {
        series.filter { $0.value.isFinite }
    }

    private static func pearson(_ pairs: [(Double, Double)]) -> Double? {
        guard pairs.count >= 2 else { return nil }
        let count = Double(pairs.count)
        let meanX = pairs.reduce(0.0) { $0 + $1.0 / count }
        let meanY = pairs.reduce(0.0) { $0 + $1.1 / count }
        let covariance = pairs.reduce(0.0) { $0 + ($1.0 - meanX) * ($1.1 - meanY) }
        let varianceX = pairs.reduce(0.0) { $0 + ($1.0 - meanX) * ($1.0 - meanX) }
        let varianceY = pairs.reduce(0.0) { $0 + ($1.1 - meanY) * ($1.1 - meanY) }
        guard covariance.isFinite, varianceX.isFinite, varianceY.isFinite,
              varianceX > 0, varianceY > 0 else { return nil }
        let denominator = sqrt(varianceX) * sqrt(varianceY)
        guard denominator.isFinite, denominator > 0 else { return nil }
        let value = covariance / denominator
        guard value.isFinite else { return nil }
        return min(1, max(-1, value))
    }
}

import Foundation

public enum LocalFactorCorrelationMethod: String, Codable, Sendable {
    case pearson
    case spearman
}

public enum LocalFactorMissingReason: String, Codable, Sendable, Equatable {
    case noFiniteObservations
    case missingAlignedObservations
    case insufficientObservations
    case constantSeries
    case missingFactorValue
    case missingPortfolioWeight
    case noExplicitPortfolioWeights
    case noUsableExposureValues
}

/// A dated factor record supplied by the caller. No market data is fetched or inferred.
public struct LocalFactorObservation: Codable, Sendable, Equatable {
    public let date: Date
    public let values: [FactorID: Double]
    public let provenance: String

    public init(date: Date, values: [FactorID: Double], provenance: String) {
        self.date = date
        self.values = values
        self.provenance = provenance
    }
}

/// A dated, symbol-specific factor record supplied by the caller.
public struct LocalFactorSymbolObservation: Codable, Sendable, Equatable {
    public let symbol: String
    public let date: Date
    public let values: [FactorID: Double]
    public let provenance: String

    public init(symbol: String, date: Date, values: [FactorID: Double], provenance: String) {
        self.symbol = symbol
        self.date = date
        self.values = values
        self.provenance = provenance
    }
}

public struct LocalFactorCorrelationResult: Codable, Sendable, Equatable {
    public let left: FactorID
    public let right: FactorID
    public let method: LocalFactorCorrelationMethod
    public let coefficient: Double?
    public let sampleCount: Int
    public let minimumObservations: Int
    public let missingReason: LocalFactorMissingReason?
    public let provenance: [String]

    public init(left: FactorID, right: FactorID, method: LocalFactorCorrelationMethod,
                coefficient: Double?, sampleCount: Int, minimumObservations: Int,
                missingReason: LocalFactorMissingReason?, provenance: [String]) {
        self.left = left; self.right = right; self.method = method
        self.coefficient = coefficient; self.sampleCount = sampleCount
        self.minimumObservations = minimumObservations; self.missingReason = missingReason
        self.provenance = provenance
    }
}

public struct LocalFactorCorrelationMatrix: Codable, Sendable, Equatable {
    public let factors: [FactorID]
    public let cells: [[LocalFactorCorrelationResult]]

    public init(factors: [FactorID], cells: [[LocalFactorCorrelationResult]]) {
        self.factors = factors
        self.cells = cells
    }
}

public enum LocalFactorExposureKind: String, Codable, Sendable {
    case portfolio
    case crossSectionalDistribution
}

public struct LocalFactorSymbolExposure: Codable, Sendable, Equatable {
    public let symbol: String
    public let factor: FactorID
    public let value: Double?
    public let explicitWeight: Double?
    public let sampleCount: Int
    public let missingReason: LocalFactorMissingReason?
    public let provenance: [String]

    public init(symbol: String, factor: FactorID, value: Double?, explicitWeight: Double?,
                sampleCount: Int, missingReason: LocalFactorMissingReason?, provenance: [String]) {
        self.symbol = symbol; self.factor = factor; self.value = value
        self.explicitWeight = explicitWeight; self.sampleCount = sampleCount
        self.missingReason = missingReason; self.provenance = provenance
    }
}

public struct LocalFactorExposureResult: Codable, Sendable, Equatable {
    public let factor: FactorID
    public let kind: LocalFactorExposureKind
    /// Weighted mean of supplied symbol factor values, normalized by total absolute weight.
    /// This is present only when explicit weights/holdings were supplied.
    public let exposure: Double?
    public let sampleCount: Int
    public let missingReason: LocalFactorMissingReason?
    public let provenance: [String]
    public let symbolExposures: [LocalFactorSymbolExposure]

    public init(factor: FactorID, kind: LocalFactorExposureKind, exposure: Double?, sampleCount: Int,
                missingReason: LocalFactorMissingReason?, provenance: [String],
                symbolExposures: [LocalFactorSymbolExposure]) {
        self.factor = factor; self.kind = kind; self.exposure = exposure
        self.sampleCount = sampleCount; self.missingReason = missingReason
        self.provenance = provenance; self.symbolExposures = symbolExposures
    }
}

public enum LocalFactorExposureAnalyzer {
    public static func correlate(_ left: FactorID, _ right: FactorID,
                                 observations: [LocalFactorObservation],
                                 method: LocalFactorCorrelationMethod = .pearson,
                                 minimumObservations: Int = 2) -> LocalFactorCorrelationResult {
        let minimum = max(2, minimumObservations)
        let records = observations.sorted { $0.date < $1.date }
        let pairs = records.compactMap { record -> (Double, Double, String)? in
            guard let x = record.values[left], x.isFinite,
                  let y = record.values[right], y.isFinite else { return nil }
            return (x, y, record.provenance)
        }
        let provenance = Array(Set(pairs.map(\.2)).sorted())
        guard !pairs.isEmpty else {
            return result(left, right, method, nil, 0, minimum, .noFiniteObservations, provenance)
        }
        guard pairs.count >= minimum else {
            return result(left, right, method, nil, pairs.count, minimum, .insufficientObservations, provenance)
        }
        let xs = pairs.map { $0.0 }, ys = pairs.map { $0.1 }
        let coefficient = method == .pearson ? correlation(xs, ys) : correlation(ranks(xs), ranks(ys))
        let reason: LocalFactorMissingReason? = coefficient == nil ? .constantSeries : nil
        return result(left, right, method, coefficient, pairs.count, minimum, reason, provenance)
    }

    /// Builds a deterministic square factor×factor matrix from caller-supplied dated records.
    /// Missing, constant or insufficiently aligned cells remain nil with an explicit reason.
    public static func correlationMatrix(_ requestedFactors: [FactorID],
                                         observations: [LocalFactorObservation],
                                         method: LocalFactorCorrelationMethod = .pearson,
                                         minimumObservations: Int = 2) -> LocalFactorCorrelationMatrix {
        var factors: [FactorID] = []
        for factor in requestedFactors where !factors.contains(factor) { factors.append(factor) }
        let cells = factors.map { left in
            factors.map { right in
                correlate(left, right, observations: observations, method: method,
                          minimumObservations: minimumObservations)
            }
        }
        return LocalFactorCorrelationMatrix(factors: factors, cells: cells)
    }

    public static func exposure(_ factor: FactorID,
                                observations: [LocalFactorSymbolObservation],
                                weights: [String: Double]? = nil,
                                minimumObservations: Int = 1) -> LocalFactorExposureResult {
        let minimum = max(1, minimumObservations)
        let grouped = Dictionary(grouping: observations.filter { !$0.symbol.isEmpty }, by: \.symbol)
        let symbols = grouped.keys.sorted()
        var rows: [LocalFactorSymbolExposure] = []
        for symbol in symbols {
            let records = grouped[symbol]!.sorted { $0.date < $1.date }
            let values = records.compactMap { record -> (Double, String)? in
                guard let value = record.values[factor], value.isFinite else { return nil }
                return (value, record.provenance)
            }
            let weight = weights?[symbol]
            let reason: LocalFactorMissingReason?
            let value: Double?
            if values.isEmpty { value = nil; reason = .noUsableExposureValues }
            else if values.count < minimum { value = nil; reason = .insufficientObservations }
            else { value = values.last!.0; reason = nil }
            rows.append(.init(symbol: symbol, factor: factor, value: value, explicitWeight: weight,
                              sampleCount: values.count, missingReason: reason,
                              provenance: Array(Set(values.map(\.1)).sorted())))
        }
        let provenance = Array(Set(rows.flatMap(\.provenance)).sorted())
        guard let weights else {
            return .init(factor: factor, kind: .crossSectionalDistribution, exposure: nil,
                         sampleCount: rows.filter { $0.value != nil }.count,
                         missingReason: rows.isEmpty ? .noUsableExposureValues : nil,
                         provenance: provenance, symbolExposures: rows)
        }
        let usable = rows.filter { $0.value != nil && $0.explicitWeight?.isFinite == true }
        guard !weights.isEmpty else {
            return .init(factor: factor, kind: .portfolio, exposure: nil, sampleCount: 0,
                         missingReason: .noExplicitPortfolioWeights, provenance: provenance,
                         symbolExposures: rows)
        }
        let valuedSymbolsWithoutWeights = rows.filter { $0.value != nil && $0.explicitWeight == nil }
        if !valuedSymbolsWithoutWeights.isEmpty {
            return .init(factor: factor, kind: .portfolio, exposure: nil, sampleCount: usable.count,
                         missingReason: .missingPortfolioWeight, provenance: provenance,
                         symbolExposures: rows)
        }
        let weightedSymbolsWithoutValues = weights.keys.filter { symbol in
            guard let row = rows.first(where: { $0.symbol == symbol }) else { return true }
            return row.value == nil || row.explicitWeight?.isFinite != true
        }
        if !weightedSymbolsWithoutValues.isEmpty {
            return .init(factor: factor, kind: .portfolio, exposure: nil, sampleCount: usable.count,
                         missingReason: .missingFactorValue, provenance: provenance,
                         symbolExposures: rows)
        }
        let denominator = usable.reduce(0.0) { $0 + abs($1.explicitWeight!) }
        guard !usable.isEmpty, denominator > 0, denominator.isFinite else {
            return .init(factor: factor, kind: .portfolio, exposure: nil, sampleCount: usable.count,
                         missingReason: .noUsableExposureValues, provenance: provenance,
                         symbolExposures: rows)
        }
        let exposure = usable.reduce(0.0) { $0 + $1.value! * $1.explicitWeight! } / denominator
        return .init(factor: factor, kind: .portfolio, exposure: exposure, sampleCount: usable.count,
                     missingReason: nil, provenance: provenance, symbolExposures: rows)
    }

    private static func result(_ left: FactorID, _ right: FactorID, _ method: LocalFactorCorrelationMethod,
                               _ coefficient: Double?, _ count: Int, _ minimum: Int,
                               _ reason: LocalFactorMissingReason?, _ provenance: [String]) -> LocalFactorCorrelationResult {
        .init(left: left, right: right, method: method, coefficient: coefficient, sampleCount: count,
              minimumObservations: minimum, missingReason: reason, provenance: provenance)
    }

    private static func correlation(_ x: [Double], _ y: [Double]) -> Double? {
        guard x.count == y.count, x.count >= 2 else { return nil }
        let mx = x.reduce(0, +) / Double(x.count), my = y.reduce(0, +) / Double(y.count)
        let dx = x.map { $0 - mx }, dy = y.map { $0 - my }
        let xx = dx.reduce(0) { $0 + $1 * $1 }, yy = dy.reduce(0) { $0 + $1 * $1 }
        guard xx > 0, yy > 0 else { return nil }
        let value = zip(dx, dy).reduce(0) { $0 + $1.0 * $1.1 } / sqrt(xx * yy)
        return value.isFinite ? min(1, max(-1, value)) : nil
    }

    private static func ranks(_ values: [Double]) -> [Double] {
        let indexed = values.enumerated().sorted { $0.element < $1.element }
        var output = Array(repeating: 0.0, count: values.count), index = 0
        while index < indexed.count {
            var end = index + 1
            while end < indexed.count && indexed[end].element == indexed[index].element { end += 1 }
            let rank = (Double(index + 1) + Double(end)) / 2
            for position in index..<end { output[indexed[position].offset] = rank }
            index = end
        }
        return output
    }
}

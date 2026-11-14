import Foundation

public struct VisualizationPoint: Sendable, Equatable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// UI-framework-free mappings from market values to normalized visualization geometry.
/// Missing/non-finite values remain unmapped instead of being coerced to a plausible value.
public enum VisualizationMapping {
    /// Returns non-negative treemap area shares. Invalid, zero, and negative values
    /// receive zero area; if no positive finite input exists, all shares are zero.
    public static func treemapAreaShares(for values: [Double]) -> [Double] {
        let nonNegative = values.map { value in
            value.isFinite && value > 0 ? value : 0
        }
        let total = nonNegative.reduce(0, +)
        guard total.isFinite, total > 0 else {
            return Array(repeating: 0, count: values.count)
        }
        return nonNegative.map { $0 / total }
    }

    /// Maps a value to a zero-based quantile color bucket.
    /// Ties share a bucket; an entirely flat reference set maps to the middle bucket.
    public static func quantileBucket(for value: Double,
                                      reference: [Double],
                                      bucketCount: Int = 5) -> Int? {
        guard value.isFinite, bucketCount > 0 else { return nil }
        let sorted = reference.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        if sorted.first == sorted.last { return bucketCount / 2 }

        var lower = 0
        var upper = sorted.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if sorted[middle] < value {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        var afterEqual = lower
        while afterEqual < sorted.count, sorted[afterEqual] == value {
            afterEqual += 1
        }
        let rank: Double
        if lower < afterEqual {
            rank = (Double(lower) + Double(afterEqual - 1)) / 2
        } else {
            rank = Double(lower)
        }
        let rankFraction = rank / Double(sorted.count)
        return min(bucketCount - 1, max(0, Int(rankFraction * Double(bucketCount))))
    }

    /// Returns the normalized position of a value/threshold on a linear axis.
    /// Values outside the range clamp to an edge; malformed or degenerate ranges return nil.
    public static func thresholdPosition(_ value: Double,
                                         minimum: Double,
                                         maximum: Double) -> Double? {
        guard value.isFinite, minimum.isFinite, maximum.isFinite, maximum > minimum else {
            return nil
        }
        return min(1, max(0, (value - minimum) / (maximum - minimum)))
    }

    /// Largest-Triangle-Three-Buckets downsampling for ordered time-series points.
    /// Invalid or non-monotonic series return no points; the selected first/last
    /// endpoints are preserved whenever the threshold is at least two.
    public static func largestTriangleThreeBuckets(_ points: [VisualizationPoint],
                                                   threshold: Int) -> [VisualizationPoint] {
        guard threshold > 0, !points.isEmpty,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return [] }
        guard points.count > 1 else { return points }
        for index in 1..<points.count where points[index - 1].x >= points[index].x { return [] }
        guard threshold < points.count else { return points }
        if threshold == 1 { return [points[0]] }
        if threshold == 2 { return [points[0], points[points.count - 1]] }

        let bucketSize = Double(points.count - 2) / Double(threshold - 2)
        var sampled = [points[0]]
        var anchorIndex = 0

        for bucket in 0..<(threshold - 2) {
            let averageStart = min(points.count - 1, Int(floor(Double(bucket + 1) * bucketSize)) + 1)
            let averageEnd = min(points.count, Int(floor(Double(bucket + 2) * bucketSize)) + 1)
            let averageRange = averageStart..<max(averageStart + 1, averageEnd)
            let averageCount = Double(averageRange.count)
            let averageX = averageRange.reduce(0.0) { $0 + points[$1].x / averageCount }
            let averageY = averageRange.reduce(0.0) { $0 + points[$1].y / averageCount }

            let rangeStart = min(points.count - 2, Int(floor(Double(bucket) * bucketSize)) + 1)
            let rangeEnd = min(points.count - 1, Int(floor(Double(bucket + 1) * bucketSize)) + 1)
            var bestIndex = rangeStart
            var maximumArea = -Double.infinity
            let anchor = points[anchorIndex]
            for candidateIndex in rangeStart..<max(rangeStart + 1, rangeEnd) {
                let candidate = points[candidateIndex]
                let area = abs((anchor.x - averageX) * (candidate.y - anchor.y)
                    - (anchor.x - candidate.x) * (averageY - anchor.y))
                if area.isFinite, area > maximumArea {
                    maximumArea = area
                    bestIndex = candidateIndex
                }
            }
            sampled.append(points[bestIndex])
            anchorIndex = bestIndex
        }
        sampled.append(points[points.count - 1])
        return sampled
    }
}

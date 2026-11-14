import XCTest
@testable import StockMonitorCore

final class VisualizationMappingTests: XCTestCase {
    func testTreemapAreaSharesAreProportionalAndSumToOne() {
        let shares = VisualizationMapping.treemapAreaShares(for: [60, 30, 10])
        XCTAssertEqual(shares[0], 0.6, accuracy: 1e-12)
        XCTAssertEqual(shares[1], 0.3, accuracy: 1e-12)
        XCTAssertEqual(shares[2], 0.1, accuracy: 1e-12)
        XCTAssertEqual(shares.reduce(0, +), 1, accuracy: 1e-12)
    }

    func testTreemapAreaKeepsInvalidOrNonPositiveValuesAtZero() {
        let shares = VisualizationMapping.treemapAreaShares(for: [2, 0, -3, .nan, .infinity])
        XCTAssertEqual(shares[0], 1, accuracy: 1e-12)
        XCTAssertEqual(Array(shares.dropFirst()), [0, 0, 0, 0])
        XCTAssertEqual(VisualizationMapping.treemapAreaShares(for: [0, -1, .nan]), [0, 0, 0])
    }

    func testQuantileBucketsRespectOrderTiesAndFlatDistributions() {
        let reference = [1.0, 2, 3, 4, 5]
        XCTAssertEqual(VisualizationMapping.quantileBucket(for: 1, reference: reference, bucketCount: 5), 0)
        XCTAssertEqual(VisualizationMapping.quantileBucket(for: 3, reference: reference, bucketCount: 5), 2)
        XCTAssertEqual(VisualizationMapping.quantileBucket(for: 5, reference: reference, bucketCount: 5), 4)
        XCTAssertEqual(VisualizationMapping.quantileBucket(for: 3, reference: [1, 2, 3, 3, 4, 5], bucketCount: 5), 2)
        XCTAssertEqual(VisualizationMapping.quantileBucket(for: 7, reference: [7, 7, 7], bucketCount: 5), 2)
    }

    func testQuantileBucketsRejectMissingInputs() {
        XCTAssertNil(VisualizationMapping.quantileBucket(for: .nan, reference: [1, 2]))
        XCTAssertNil(VisualizationMapping.quantileBucket(for: 1, reference: [.nan, .infinity]))
        XCTAssertNil(VisualizationMapping.quantileBucket(for: 1, reference: [1, 2], bucketCount: 0))
    }

    func testThresholdPositionIsLinearClampedAndRejectsDegenerateAxis() {
        XCTAssertEqual(VisualizationMapping.thresholdPosition(75, minimum: 0, maximum: 100)!, 0.75, accuracy: 1e-12)
        XCTAssertEqual(VisualizationMapping.thresholdPosition(-10, minimum: 0, maximum: 100), 0)
        XCTAssertEqual(VisualizationMapping.thresholdPosition(120, minimum: 0, maximum: 100), 1)
        XCTAssertNil(VisualizationMapping.thresholdPosition(2, minimum: 2, maximum: 2))
        XCTAssertNil(VisualizationMapping.thresholdPosition(.infinity, minimum: 0, maximum: 5))
    }

    func testLTTBDownsamplingPreservesEndpointsTargetCountAndPeak() {
        let points = (0..<5).map { VisualizationPoint(x: Double($0), y: $0 == 2 ? 10 : 0) }
        let sampled = VisualizationMapping.largestTriangleThreeBuckets(points, threshold: 3)

        XCTAssertEqual(sampled.count, 3)
        XCTAssertEqual(sampled.first, points.first)
        XCTAssertEqual(sampled.last, points.last)
        XCTAssertTrue(sampled.contains(points[2]))
        for threshold in 2...points.count {
            let result = VisualizationMapping.largestTriangleThreeBuckets(points, threshold: threshold)
            XCTAssertEqual(result.count, threshold)
            XCTAssertEqual(result.first, points.first)
            XCTAssertEqual(result.last, points.last)
        }
    }

    func testLTTBHandlesSmallThresholdsAndRejectsMalformedSeries() {
        let points = [VisualizationPoint(x: 1, y: 2), VisualizationPoint(x: 2, y: 3),
                      VisualizationPoint(x: 3, y: 1)]
        XCTAssertEqual(VisualizationMapping.largestTriangleThreeBuckets(points, threshold: 1), [points[0]])
        XCTAssertEqual(VisualizationMapping.largestTriangleThreeBuckets(points, threshold: 2), [points[0], points[2]])
        XCTAssertEqual(VisualizationMapping.largestTriangleThreeBuckets(points, threshold: 0), [])
        XCTAssertEqual(VisualizationMapping.largestTriangleThreeBuckets(
            [points[0], VisualizationPoint(x: 2, y: .nan), points[2]], threshold: 2), [])
        XCTAssertEqual(VisualizationMapping.largestTriangleThreeBuckets(
            [points[1], points[0], points[2]], threshold: 2), [])
    }
}

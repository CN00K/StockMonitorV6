import XCTest
@testable import StockMonitorCore

final class LocalFactorExposureTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    func testPearsonUsesOnlyAlignedDatedFiniteFactorValuesAndRecordsProvenance() throws {
        let observations = [
            observation(0, [.peTTM: 1, .pb: 2], "daily-basic"),
            observation(1, [.peTTM: 2, .pb: 4], "daily-basic"),
            observation(2, [.peTTM: 3], "daily-basic"),
            observation(3, [.peTTM: .infinity, .pb: 8], "bad-record"),
            observation(4, [.peTTM: 4, .pb: 8], "fundamentals")
        ]

        let result = LocalFactorExposureAnalyzer.correlate(.peTTM, .pb, observations: observations,
                                                           method: .pearson, minimumObservations: 3)

        XCTAssertEqual(result.coefficient!, 1, accuracy: 1e-12)
        XCTAssertEqual(result.sampleCount, 3)
        XCTAssertEqual(result.provenance, ["daily-basic", "fundamentals"])
        XCTAssertNil(result.missingReason)
    }

    func testSpearmanIsTieAwareAndConstantSeriesIsUnknown() throws {
        let observations = (0..<4).map { index in
            observation(index, [.peTTM: Double([1, 2, 2, 4][index]), .pb: Double([4, 3, 2, 1][index])], "local")
        }
        let result = LocalFactorExposureAnalyzer.correlate(.peTTM, .pb, observations: observations,
                                                           method: .spearman, minimumObservations: 4)
        XCTAssertEqual(result.coefficient!, -0.9486832980505138, accuracy: 1e-12)

        let constant = LocalFactorExposureAnalyzer.correlate(.peTTM, .pb,
            observations: (0..<4).map { observation($0, [.peTTM: 1, .pb: 2], "constant") }, minimumObservations: 2)
        XCTAssertNil(constant.coefficient)
        XCTAssertEqual(constant.missingReason, .constantSeries)
    }

    func testInsufficientAndMissingAlignedSeriesRemainUnknown() {
        let result = LocalFactorExposureAnalyzer.correlate(.peTTM, .pb,
            observations: [observation(0, [.peTTM: 1], "local"), observation(1, [.pb: 2], "local")],
            minimumObservations: 2)
        XCTAssertNil(result.coefficient)
        XCTAssertEqual(result.sampleCount, 0)
        XCTAssertEqual(result.missingReason, .noFiniteObservations)
    }

    func testFactorCorrelationMatrixIsSymmetricAndKeepsUnavailableCellsUnknown() {
        let observations = [
            observation(0, [.peTTM: 1, .pb: 3, .roe: 9], "local"),
            observation(1, [.peTTM: 2, .pb: 2], "local"),
            observation(2, [.peTTM: 3, .pb: 1], "local")
        ]
        let matrix = LocalFactorExposureAnalyzer.correlationMatrix(
            [.peTTM, .pb, .roe, .pb], observations: observations, minimumObservations: 2)
        XCTAssertEqual(matrix.factors, [.peTTM, .pb, .roe])
        XCTAssertEqual(matrix.cells.count, 3)
        XCTAssertTrue(matrix.cells.allSatisfy { $0.count == 3 })
        XCTAssertEqual(matrix.cells[0][1].coefficient!, matrix.cells[1][0].coefficient!, accuracy: 1e-12)
        XCTAssertEqual(matrix.cells[0][0].coefficient!, 1, accuracy: 1e-12)
        XCTAssertNil(matrix.cells[1][2].coefficient)
        XCTAssertEqual(matrix.cells[1][2].missingReason, .insufficientObservations)
    }

    func testExplicitWeightsProducePortfolioExposureAndNoWeightsAreCrossSectionalOnly() {
        let records = [
            symbolObservation("A", 0, [.roe: 1], "fina"),
            symbolObservation("B", 0, [.roe: 3], "fina")
        ]
        let portfolio = LocalFactorExposureAnalyzer.exposure(.roe, observations: records,
                                                              weights: ["A": 1, "B": 3])
        XCTAssertEqual(portfolio.kind, .portfolio)
        XCTAssertEqual(portfolio.exposure!, 2.5, accuracy: 1e-12)
        XCTAssertEqual(portfolio.sampleCount, 2)

        let distribution = LocalFactorExposureAnalyzer.exposure(.roe, observations: records)
        XCTAssertEqual(distribution.kind, .crossSectionalDistribution)
        XCTAssertNil(distribution.exposure)
        XCTAssertEqual(distribution.symbolExposures.map(\.symbol), ["A", "B"])
    }

    func testMissingWeightCannotBecomePortfolioExposure() {
        let result = LocalFactorExposureAnalyzer.exposure(.roe,
            observations: [symbolObservation("A", 0, [.roe: 2], "fina"), symbolObservation("B", 0, [.roe: 4], "fina")],
            weights: ["A": 1])
        XCTAssertEqual(result.kind, .portfolio)
        XCTAssertNil(result.exposure)
        XCTAssertEqual(result.sampleCount, 1)
        XCTAssertTrue(result.symbolExposures.contains { $0.symbol == "B" && $0.explicitWeight == nil })
    }

    private func observation(_ day: Int, _ values: [FactorID: Double], _ provenance: String) -> LocalFactorObservation {
        .init(date: base.addingTimeInterval(Double(day) * 86_400), values: values, provenance: provenance)
    }

    private func symbolObservation(_ symbol: String, _ day: Int, _ values: [FactorID: Double], _ provenance: String) -> LocalFactorSymbolObservation {
        .init(symbol: symbol, date: base.addingTimeInterval(Double(day) * 86_400), values: values, provenance: provenance)
    }
}

import XCTest
@testable import StockMonitorCore

final class LocalCorrelationAnalysisTests: XCTestCase {
    func testUnadjustedDailyReturnMatrixAlignsSessionsAndFindsPerfectCorrelations() throws {
        let dates = (0..<4).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 86_400) }
        let closes: [String: [Double]] = [
            "A": [100, 110, 99, 108.9],
            "B": [200, 220, 198, 217.8],
            "C": [100, 90, 99, 89.1]
        ]
        let bars = closes.flatMap { code, values in
            values.enumerated().map { index, close in
                DailyBar(code: code, name: code, tradeDate: dates[index], open: close,
                    high: close, low: close, close: close, volume: 100)
            }
        }

        let matrix = LocalCorrelationAnalyzer.returnMatrix(bars: bars, minimumObservations: 3)

        XCTAssertEqual(matrix.seriesIDs, ["A", "B", "C"])
        XCTAssertEqual(matrix.observationCounts[0][1], 3)
        XCTAssertEqual(try XCTUnwrap(matrix.coefficients[0][1]), 1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(matrix.coefficients[0][2]), -1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(matrix.coefficients[1][1]), 1, accuracy: 1e-12)
        XCTAssertTrue(matrix.warnings.contains { $0.contains("unadjusted") })
    }

    func testGenericMatrixKeepsInsufficientAndConstantPairsUnknown() throws {
        let d1 = Date(timeIntervalSince1970: 1_700_000_000)
        let d2 = d1.addingTimeInterval(86_400)
        let d3 = d2.addingTimeInterval(86_400)
        let matrix = LocalCorrelationAnalyzer.matrix(series: [
            "constant": [d1: 1, d2: 1, d3: 1],
            "short": [d1: 1, d2: 2],
            "varying": [d1: 1, d2: 3, d3: 2]
        ], minimumObservations: 3)

        XCTAssertEqual(matrix.observationCounts[0][1], 2)
        XCTAssertNil(matrix.coefficients[0][0])
        XCTAssertNil(matrix.coefficients[0][1])
        XCTAssertNil(matrix.coefficients[1][1])
        XCTAssertEqual(try XCTUnwrap(matrix.coefficients[2][2]), 1, accuracy: 1e-12)
        XCTAssertEqual(LocalCorrelationAnalyzer.matrix(series: [:]).seriesIDs, [])
    }

    func testAdjustedAndDuplicateSessionBarsAreExcludedWithWarning() {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let other = date.addingTimeInterval(86_400)
        let bars = [
            bar("A", date, close: 100), bar("A", date, close: 101),
            bar("A", other, close: 110), bar("B", date, close: 200),
            bar("B", other, close: 220, adjustment: "qfq")
        ]
        let matrix = LocalCorrelationAnalyzer.returnMatrix(bars: bars, minimumObservations: 2)

        XCTAssertEqual(matrix.seriesIDs, ["A", "B"])
        XCTAssertTrue(matrix.warnings.contains { $0.contains("Duplicate") })
        XCTAssertNil(matrix.coefficients[0][0])
    }

    private func bar(_ code: String, _ date: Date, close: Double,
                     adjustment: String = "none") -> DailyBar {
        DailyBar(code: code, name: code, tradeDate: date, open: close, high: close,
            low: close, close: close, volume: 100, priceAdjustment: adjustment)
    }
}

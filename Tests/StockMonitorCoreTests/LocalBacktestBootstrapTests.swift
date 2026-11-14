import XCTest
@testable import StockMonitorCore

final class LocalBacktestBootstrapTests: XCTestCase {
    func testBootstrapIsDeterministicAndReturnsOrderedFiveFiftyNinetyFiveBands() throws {
        let returns = [0.04, -0.03, 0.02, -0.01, 0.0]
        let first = try XCTUnwrap(LocalBacktestBootstrap.run(
            returns: returns, pathCount: 200, horizon: 20, seed: 42))
        let second = try XCTUnwrap(LocalBacktestBootstrap.run(
            returns: returns, pathCount: 200, horizon: 20, seed: 42))

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sampleReturnCount, returns.count)
        XCTAssertEqual(first.pathCount, 200)
        XCTAssertEqual(first.horizon, 20)
        XCTAssertEqual(first.lower5Equity.count, 21)
        for index in first.lower5Equity.indices {
            XCTAssertLessThanOrEqual(first.lower5Equity[index], first.medianEquity[index])
            XCTAssertLessThanOrEqual(first.medianEquity[index], first.upper95Equity[index])
        }
        XCTAssertGreaterThanOrEqual(first.medianMaximumDrawdown, 0)
        XCTAssertLessThanOrEqual(first.maximumDrawdown95, 1)
        XCTAssertTrue(first.warnings.contains { $0.contains("not a forecast") })
    }

    func testBootstrapRejectsMissingOrImpossibleReturnsAndHandlesTotalLoss() throws {
        XCTAssertNil(LocalBacktestBootstrap.run(returns: []))
        XCTAssertNil(LocalBacktestBootstrap.run(returns: [0.1, .nan]))
        XCTAssertNil(LocalBacktestBootstrap.run(returns: [-1.01]))
        let totalLoss = try XCTUnwrap(LocalBacktestBootstrap.run(
            returns: [-1], pathCount: 8, horizon: 3, seed: 1))
        XCTAssertEqual(totalLoss.medianEquity, [1, 0, 0, 0])
        XCTAssertEqual(totalLoss.medianMaximumDrawdown, 1)
    }
}

import XCTest
@testable import StockMonitorCore

final class FactorAndSectorTests: XCTestCase {
    func testRequestedFactorSetContainsNineteenDefinitions() {
        XCTAssertEqual(FactorID.allCases.count, 19)
        XCTAssertEqual(FactorSubset.definitions.count, FactorID.allCases.count)
    }

    func testMomentumMatchesPercentChangeFormula() {
        let closes: [Double] = [100, 101, 102, 103, 104, 110]
        let observations = closes.map { FactorObservation(close: $0) }
        XCTAssertEqual(FactorSubset.value(for: .momentum5, observations: observations)!, 0.1, accuracy: 1e-12)
    }

    func testAmountFactorUsesUpstreamUnitConversion() {
        let observations = (1...20).map { _ in FactorObservation(amount: 100_000) }
        XCTAssertEqual(FactorSubset.value(for: .amount20, observations: observations)!, 1, accuracy: 1e-12)
    }

    func testMADWinsorizationAndZScore() {
        let clipped = FactorNormalization.winsorizeMAD([0.0, 1, 2, 3, 100].map { Optional<Double>($0) })
        XCTAssertEqual(clipped[4]!, 2 + 3 * 1.4826 * 1, accuracy: 1e-12)
        let normalized = FactorNormalization.standardizeZScore([1.0, 2, 3].map { Optional<Double>($0) })
        XCTAssertEqual(normalized[0]!, -1, accuracy: 1e-12)
        XCTAssertEqual(normalized[1]!, 0, accuracy: 1e-12)
        XCTAssertEqual(normalized[2]!, 1, accuracy: 1e-12)
    }

    func testNeutralizationDemeansOnlyWithinProvidedGroups() {
        let result = FactorNormalization.neutralizeByGroup([1.0, 3, 10].map { Optional<Double>($0) }, groups: ["A", "A", "B"])
        XCTAssertEqual(result[0]!, -1, accuracy: 1e-12)
        XCTAssertEqual(result[1]!, 1, accuracy: 1e-12)
        XCTAssertEqual(result[2]!, 0, accuracy: 1e-12)
    }

    func testSectorTaggerMapsAndDeduplicatesCandidates() throws {
        let data = Data(#"{"title_sector_map":{"人工智能":["AI","算力"],"算力":["算力","数据中心"]},"sector_synonyms":{"人工智能":"AI"},"cluster_pools":{"tech":{"keywords":["大模型"],"sectors":["AI","云计算"]}}}"#.utf8)
        let tagger = try SectorTagger(data: data)
        XCTAssertEqual(tagger.tags(in: "人工智能和大模型"), ["AI", "算力", "云计算"])
    }
}

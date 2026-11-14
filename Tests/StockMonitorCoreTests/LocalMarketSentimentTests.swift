import XCTest
@testable import StockMonitorCore

final class LocalMarketSentimentTests: XCTestCase {
    private let metadata = LocalMarketSentimentMetadata(
        provenance: "test fixture", sampleDescription: "explicit measured sample", sampleCount: 10)

    private func observation(_ score: Double, weight: Double = 1) -> LocalMarketSentimentObservation {
        .init(score: score, weight: weight, metadata: metadata)
    }

    func testAllMissingProducesUnknownAndListsEveryComponent() {
        let result = LocalMarketSentiment.score([:])

        XCTAssertNil(result.score)
        XCTAssertNil(result.band)
        XCTAssertTrue(result.includedComponents.isEmpty)
        XCTAssertEqual(result.excludedComponents.count, LocalMarketSentimentComponent.allCases.count)
        XCTAssertTrue(result.excludedComponents.allSatisfy { $0.reason == .missing })
    }

    func testPartialCoverageExcludesMissingWithoutAutoFill() {
        let result = LocalMarketSentiment.score([
            .advancingDecliningBreadth: observation(0.8),
            .moneyFlowDirection: observation(-0.2)
        ])

        XCTAssertEqual(result.score!, 0.3, accuracy: 1e-12)
        XCTAssertEqual(result.band, .strong)
        XCTAssertEqual(result.includedComponents, [.advancingDecliningBreadth, .moneyFlowDirection])
        XCTAssertEqual(result.excludedComponents.filter { $0.reason == .missing }.count, 4)
    }

    func testWeightsAreRenormalizedOverValidPresentComponents() {
        let result = LocalMarketSentiment.score([
            .returnDistribution: observation(1, weight: 3),
            .limitUpDownBalance: observation(-1, weight: 1),
            .marketParticipation: observation(0, weight: 0)
        ])

        XCTAssertEqual(result.score!, 0.5, accuracy: 1e-12)
        XCTAssertEqual(result.includedComponents, [.returnDistribution, .limitUpDownBalance, .marketParticipation])
    }

    func testInvalidScoreAndWeightAreExcludedAndListed() {
        let result = LocalMarketSentiment.score([
            .sealBreakPressure: observation(.nan),
            .moneyFlowDirection: observation(0.1, weight: -.leastNormalMagnitude),
            .marketParticipation: observation(.infinity)
        ])

        XCTAssertNil(result.score)
        XCTAssertEqual(result.excludedComponents.first { $0.component == .sealBreakPressure }?.reason, .invalidScore)
        XCTAssertEqual(result.excludedComponents.first { $0.component == .moneyFlowDirection }?.reason, .invalidWeight)
        XCTAssertEqual(result.excludedComponents.first { $0.component == .marketParticipation }?.reason, .invalidScore)
    }

    func testDisplayBandBoundariesAreDocumentedAndStable() {
        XCTAssertEqual(LocalMarketSentimentBand.forScore(-1), .veryWeak)
        XCTAssertEqual(LocalMarketSentimentBand.forScore(-0.6000000001), .veryWeak)
        XCTAssertEqual(LocalMarketSentimentBand.forScore(-0.6), .weak)
        XCTAssertEqual(LocalMarketSentimentBand.forScore(-0.2), .balanced)
        XCTAssertEqual(LocalMarketSentimentBand.forScore(0.2), .strong)
        XCTAssertEqual(LocalMarketSentimentBand.forScore(0.6), .veryStrong)
        XCTAssertNil(LocalMarketSentimentBand.forScore(.nan))
    }

    func testSameInputsProduceDeterministicResultAndOrdering() {
        let inputs: [LocalMarketSentimentComponent: LocalMarketSentimentObservation] = [
            .moneyFlowDirection: observation(0.4, weight: 2),
            .advancingDecliningBreadth: observation(-0.1, weight: 1),
            .limitUpDownBalance: observation(0.8, weight: 1)
        ]

        let first = LocalMarketSentiment.score(inputs)
        let second = LocalMarketSentiment.score(inputs)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.includedComponents, [.advancingDecliningBreadth, .limitUpDownBalance, .moneyFlowDirection])
        XCTAssertEqual(first.excludedComponents.map(\.component), [.returnDistribution, .sealBreakPressure, .marketParticipation])
    }
}

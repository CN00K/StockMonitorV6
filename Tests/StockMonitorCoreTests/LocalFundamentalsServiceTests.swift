import Foundation
import XCTest
@testable import StockMonitorCore

final class LocalFundamentalsServiceTests: XCTestCase {
    func testExplicitRefreshIsBoundedAndPersistsOnlyReturnedFields() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("local-fundamentals-\(UUID().uuidString)")
        let store = SQLiteMonitorStore(databaseURL: directory.appendingPathComponent("monitor.sqlite"),
                                       appGroupIdentifier: nil)
        let source = RecordingFundamentalsProvider()
        let service = LocalFundamentalsService(source: source, store: store, maximumCodes: 2)

        let report = await service.refresh(codes: ["600000", "000002", "bad", "000001"])
        let requested = await source.requestedCodes
        XCTAssertEqual(requested, ["000001", "000002"])
        XCTAssertEqual(report.requestedCodes, ["000001", "000002", "600000"])
        XCTAssertEqual(report.skippedCodes, ["600000"])
        XCTAssertEqual(report.snapshots.count, 2)
        XCTAssertEqual(report.status.requestCount, 2)
        let cached = try await service.latest(codes: ["000001", "000002", "600000"])
        XCTAssertEqual(cached.map(\.code), ["000001", "000002"])
        XCTAssertTrue(cached.allSatisfy { $0.unavailableFields.contains("peTTM") })
        let observations = try await service.latestFactorObservations(codes: ["000001", "000002"])
        XCTAssertEqual(observations["000001"]?.pb, 0.46)
        XCTAssertEqual(observations["000001"]?.roe, 5.2)
        XCTAssertEqual(observations["000001"]?.grossProfitMargin, 10)
        XCTAssertNil(observations["000001"]?.peTTM, "dynamic PE is not PE-TTM")
    }
}

private actor RecordingFundamentalsProvider: MarketFundamentalsProviding {
    private(set) var requestedCodes: [String] = []

    func fetch(code: String) async throws -> EastmoneyFundamentalSnapshot {
        requestedCodes.append(code)
        return EastmoneyFundamentalSnapshot(code: code, name: code, peDynamic: 6.4,
            pb: 0.46, roe: 5.2, grossMargin: 10,
            unavailableFields: ["peTTM", "roe"], fetchedAt: Date())
    }
}

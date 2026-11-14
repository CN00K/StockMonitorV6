import XCTest
@testable import StockMonitorCore

final class EastmoneyFundamentalsSourceTests: XCTestCase {
    private func fixtureData() throws -> Data {
        let fixture = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Fixtures/eastmoney-f10-sh600000.json")
        return try Data(contentsOf: fixture)
    }

    func testParsesCapturedFixtureAndNormalizesRawValuationUnits() throws {
        let snapshot = try EastmoneyFundamentalsSource.parse(data: fixtureData())
        XCTAssertEqual(snapshot.code, "600000")
        XCTAssertEqual(snapshot.name, "浦发银行")
        XCTAssertEqual(snapshot.peDynamic ?? -1, 6.40, accuracy: 1e-12)
        XCTAssertEqual(snapshot.pb ?? -1, 0.46, accuracy: 1e-12)
        XCTAssertEqual(snapshot.totalMarketValue ?? -1, 346_380_718_320, accuracy: 0.1)
        XCTAssertEqual(snapshot.floatMarketValue ?? -1, 346_380_718_320, accuracy: 0.1)
        XCTAssertEqual(snapshot.roe ?? -1, 5.2, accuracy: 1e-12)
        XCTAssertEqual(snapshot.grossMargin ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(snapshot.netMargin ?? -1, 29.774927063, accuracy: 1e-12)
        XCTAssertEqual(snapshot.netProfit ?? -1, 40_572_000_000, accuracy: 0.1)
        XCTAssertEqual(snapshot.industry, "银行Ⅱ")
        XCTAssertTrue(snapshot.unavailableFields.isEmpty)
    }

    func testFactorObservationOnlyMapsSupportedProperties() throws {
        let snapshot = try EastmoneyFundamentalsSource.parse(data: fixtureData())
        let observation = snapshot.factorObservation
        XCTAssertNil(observation.peTTM, "dynamic PE must not be labeled PE-TTM")
        XCTAssertEqual(observation.pb ?? -1, 0.46, accuracy: 1e-12)
        XCTAssertEqual(observation.totalMarketValue ?? -1, 346_380_718_320, accuracy: 0.1)
        XCTAssertEqual(observation.roe ?? -1, 5.2, accuracy: 1e-12)
        XCTAssertEqual(observation.grossProfitMargin ?? -1, 0, accuracy: 1e-12)
        XCTAssertNil(observation.psTTM)
        XCTAssertNil(observation.dvTTM)
        XCTAssertNil(observation.roa)
        XCTAssertNil(observation.revenueYoY)
        XCTAssertNil(observation.netProfitYoY)
    }

    func testMapsSecurityIDsAndRejectsUnknownMarkets() throws {
        XCTAssertEqual(try EastmoneyFundamentalsSource.securityID(for: "600000"), "1.600000")
        XCTAssertEqual(try EastmoneyFundamentalsSource.securityID(for: "900901"), "1.900901")
        XCTAssertEqual(try EastmoneyFundamentalsSource.securityID(for: "000001"), "0.000001")
        XCTAssertEqual(try EastmoneyFundamentalsSource.securityID(for: "430001"), "0.430001")
        XCTAssertEqual(try EastmoneyFundamentalsSource.securityID(for: "830001"), "0.830001")
        XCTAssertThrowsError(try EastmoneyFundamentalsSource.securityID(for: "12345"))
        XCTAssertThrowsError(try EastmoneyFundamentalsSource.securityID(for: "100001"))
    }

    func testMalformedHTMLAndNonObjectJSONAreRejected() {
        XCTAssertThrowsError(try EastmoneyFundamentalsSource.parse(data: Data("<html>challenge</html>".utf8))) { error in
            XCTAssertEqual(error as? EastmoneyFundamentalsError, .nonJSONResponse)
        }
        XCTAssertThrowsError(try EastmoneyFundamentalsSource.parse(data: Data("not json".utf8))) { error in
            XCTAssertEqual(error as? EastmoneyFundamentalsError, .nonJSONResponse)
        }
        XCTAssertThrowsError(try EastmoneyFundamentalsSource.parse(data: Data("{\"data\":null}".utf8))) { error in
            XCTAssertEqual(error as? EastmoneyFundamentalsError, .malformedResponse)
        }
    }

    func testHTTPErrorIsExplicitAndDoesNotBecomeAValidSnapshot() {
        let error = EastmoneyFundamentalsError.httpStatus(503)
        XCTAssertEqual(error.localizedDescription, "Eastmoney fundamentals HTTP status 503")
        XCTAssertEqual(error, .httpStatus(503))
    }

    func testMissingFieldsRemainNilAndUnavailable() throws {
        let body = Data("{\"rc\":0,\"data\":{\"f57\":\"600000\",\"f162\":640,\"f186\":0}}".utf8)
        let snapshot = try EastmoneyFundamentalsSource.parse(data: body)
        XCTAssertEqual(snapshot.peDynamic ?? -1, 6.40, accuracy: 1e-12)
        XCTAssertEqual(snapshot.grossMargin ?? -1, 0, accuracy: 1e-12)
        XCTAssertNil(snapshot.pb)
        XCTAssertNil(snapshot.netProfit)
        XCTAssertTrue(snapshot.unavailableFields.contains("pb"))
        XCTAssertTrue(snapshot.unavailableFields.contains("netProfit"))
        XCTAssertTrue(snapshot.unavailableFields.contains("industry"))
    }

    func testRawValuationAndCurrencyUnitsAreNotAlteredBeyondDocumentedRule() throws {
        let body = Data("{\"data\":{\"f162\":0,\"f167\":100,\"f116\":123.5,\"f117\":99.25,\"f105\":-4.0,\"f173\":-2.5}}".utf8)
        let snapshot = try EastmoneyFundamentalsSource.parse(data: body)
        XCTAssertEqual(snapshot.peDynamic, 0)
        XCTAssertEqual(snapshot.pb, 1)
        XCTAssertEqual(snapshot.totalMarketValue, 123.5)
        XCTAssertEqual(snapshot.floatMarketValue, 99.25)
        XCTAssertEqual(snapshot.netProfit, -4)
        XCTAssertEqual(snapshot.roe, -2.5)
    }
}

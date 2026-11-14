import XCTest
@testable import StockMonitorCore

final class QuoteSourceTests: XCTestCase {
    func testSinaJSONPParserExtractsQuoteAndFractionalVolume() throws {
        var fields = Array(repeating: "0", count: 32)
        fields[0] = "浦发银行"
        fields[1] = "10.01"
        fields[2] = "10.00"
        fields[3] = "10.10"
        fields[4] = "10.20"
        fields[5] = "9.98"
        fields[8] = "1000.00"
        fields[9] = "101000.5"
        fields[30] = "2026-11-13"
        fields[31] = "15:00:00"
        let response = "var hq_str_sh600000=\"\(fields.joined(separator: ","))\";"
        let quotes = SinaQuoteSource.parse(response)
        let quote = try XCTUnwrap(quotes.first)
        XCTAssertEqual(quote.code, "600000")
        XCTAssertEqual(quote.name, "浦发银行")
        XCTAssertEqual(quote.price, 10.10, accuracy: 1e-12)
        XCTAssertEqual(quote.volume, 1_000)
        XCTAssertEqual(quote.amount, 101_000.5)
    }

    func testRecordedSinaResponseParsesRequiredQuoteFields() throws {
        let text = try String(contentsOf: fixtureURL("sina-sh600000.raw.utf8.txt"), encoding: .utf8)
        let quote = try XCTUnwrap(SinaQuoteSource.parse(text).first)
        XCTAssertEqual(quote.code, "600000")
        XCTAssertEqual(quote.name, "浦发银行")
        XCTAssertEqual(quote.volume, 76_157_313)
        XCTAssertEqual(quote.amount ?? 0, 786_507_841, accuracy: 0.1)
        XCTAssertNil(quote.volumeRatio)
        XCTAssertNil(quote.turnoverRate)
    }

    func testRecordedTencentResponseParsesOptionalMetricsAndMarketCapUnits() throws {
        let text = try String(contentsOf: fixtureURL("tencent-sh600000.raw.utf8.txt"), encoding: .utf8)
        let symbols: [String: (code: String, kind: QuoteKind, name: String?)] = [
            "sh600000": ("600000", .stock, nil)
        ]
        let quote = try XCTUnwrap(TencentQuoteSource.parse(text, symbols: symbols, retrievedAt: Date()).first)
        XCTAssertEqual(quote.code, "600000")
        XCTAssertEqual(quote.turnoverRate ?? 0, 0.23, accuracy: 0.001)
        XCTAssertEqual(quote.volumeRatio ?? 0, 1.45, accuracy: 0.001)
        XCTAssertEqual(quote.dynamicPE ?? 0, 6.69, accuracy: 0.001)
        XCTAssertEqual(quote.totalMarketValue ?? 0, 346_381_000_000, accuracy: 100_000)
        XCTAssertEqual(quote.floatMarketValue ?? 0, 346_381_000_000, accuracy: 100_000)
        XCTAssertEqual(quote.amount ?? 0, 786_510_000, accuracy: 1)
        XCTAssertNil(quote.mainNetInflow)
    }

    func testRecordedEastmoneyResponseMapsQuoteAndFlowFieldsSeparately() throws {
        let data = try Data(contentsOf: fixtureURL("eastmoney-quote-sh600000.json"))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(root["data"] as? [String: Any])
        let rows = try XCTUnwrap(payload["diff"] as? [[String: Any]])
        let quote = try XCTUnwrap(EastmoneyQuoteSource.parse(rows, indicesBySecID: [:], retrievedAt: Date()).first)
        XCTAssertEqual(quote.turnoverRate ?? 0, 0.23, accuracy: 0.001)
        XCTAssertEqual(quote.volumeRatio ?? 0, 1.45, accuracy: 0.001)
        XCTAssertEqual(quote.dynamicPE ?? 0, 6.4, accuracy: 0.001)
        XCTAssertEqual(quote.totalMarketValue ?? 0, 346_380_718_320, accuracy: 0.1)
        XCTAssertEqual(quote.floatMarketValue ?? 0, 346_380_718_320, accuracy: 0.1)
        XCTAssertEqual(quote.mainNetInflow ?? 0, 89_217_910, accuracy: 0.1)
        XCTAssertEqual(quote.moneyFlowSourceID, "eastmoney.clist.f62")
        XCTAssertNotNil(quote.moneyFlowTimestamp)
    }

    func testOlderStoredQuoteWithoutNewOptionalFieldsStillDecodes() throws {
        let json = #"{"code":"600000","name":"浦发银行","timestamp":"2026-11-13T07:00:00Z","price":10.4,"previousClose":10.21,"open":10.19,"high":10.44,"low":10.12,"volume":761573,"amount":786507841,"sourceID":"eastmoney","retrievedAt":"2026-11-13T07:00:00Z","timestampIsProvider":true,"kind":"stock"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let quote = try decoder.decode(Quote.self, from: Data(json.utf8))
        XCTAssertNil(quote.turnoverRate)
        XCTAssertNil(quote.volumeRatio)
        XCTAssertNil(quote.mainNetInflow)
        XCTAssertEqual(quote.code, "600000")
    }

    private func fixtureURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../Resources/Fixtures/\(name)").standardizedFileURL
    }
}

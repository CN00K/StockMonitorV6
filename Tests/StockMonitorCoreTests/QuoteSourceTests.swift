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
}

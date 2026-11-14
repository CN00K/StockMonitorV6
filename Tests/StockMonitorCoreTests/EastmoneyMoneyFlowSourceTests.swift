import Foundation
import XCTest
@testable import StockMonitorCore

final class EastmoneyMoneyFlowSourceTests: XCTestCase {
    func testRecordedEastmoneyFlowFixtureParsesObservedSixColumns() throws {
        let data = try fixture("eastmoney-fflow-sh600000.json")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let payload = try XCTUnwrap(root["data"] as? [String: Any])
        let lines = try XCTUnwrap(payload["klines"] as? [String])
        XCTAssertEqual(payload["code"] as? String, "600000")
        XCTAssertEqual(lines.count, 240)

        let firstLine = try XCTUnwrap(lines.first)
        let first = try XCTUnwrap(EastmoneyMoneyFlowSource.parse([firstLine], code: "600000").first)
        XCTAssertEqual(first.timestamp.timeIntervalSince1970, try XCTUnwrap(DateFormatter.fixtureMinute().date(from: "2026-11-13 09:31")).timeIntervalSince1970, accuracy: 0.1)
        XCTAssertEqual(first.mainNetInflow, 1_244_067.0, accuracy: 0.001)
        XCTAssertEqual(first.smallNetInflow, -708_974.0, accuracy: 0.001)
        XCTAssertEqual(first.mediumNetInflow, -534_080.0, accuracy: 0.001)
        XCTAssertEqual(first.largeNetInflow, 1_000_085.0, accuracy: 0.001)
        XCTAssertEqual(first.superLargeNetInflow, 243_982.0, accuracy: 0.001)
        XCTAssertEqual(first.sourceID, "eastmoney_fflow")
    }

    func testMalformedRowsAndInvalidCodeAreRejected() {
        XCTAssertTrue(EastmoneyMoneyFlowSource.parse(["bad,1,2,3,4,5"], code: "600000").isEmpty)
        XCTAssertTrue(EastmoneyMoneyFlowSource.parse(["2026-11-13 09:31,1,2,3,4"], code: "600000").isEmpty)
        XCTAssertTrue(EastmoneyMoneyFlowSource.parse(["2026-11-13 09:31,NaN,2,3,4,5"], code: "600000").isEmpty)
        XCTAssertTrue(EastmoneyMoneyFlowSource.parse(["2026-11-13 09:31,1,2,3,4,5"], code: "60000x").isEmpty)
        XCTAssertNil(EastmoneyMoneyFlowSource.requestURL(code: "bad"))
    }

    func testRequestURLUsesTheObservedRealtimeFlowEndpointAndFields() throws {
        let url = try XCTUnwrap(EastmoneyMoneyFlowSource.requestURL(code: "600000"))
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(parts.host, "push2.eastmoney.com")
        XCTAssertEqual(parts.path, "/api/qt/stock/fflow/kline/get")
        let query = Dictionary(uniqueKeysWithValues: (parts.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["secid"], "1.600000")
        XCTAssertEqual(query["klt"], "1")
        XCTAssertTrue(query["fields2"]?.contains("f52") == true)
    }

    private func fixture(_ name: String) throws -> Data {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let file = tests.appendingPathComponent("../../Resources/Fixtures/\(name)").standardizedFileURL
        return try Data(contentsOf: file)
    }
}

private extension DateFormatter {
    static func fixtureMinute() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }
}

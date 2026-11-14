import XCTest
@testable import StockMonitorCore

final class StockMonitorRouteTests: XCTestCase {
    func testParsesEachExistingTabRoute() {
        for tab in StockMonitorTab.allCases {
            let url = URL(string: "stockmonitor://tab/\(tab.rawValue)")
            XCTAssertNotNil(url)
            XCTAssertEqual(url.flatMap(StockMonitorRoute.init), .tab(tab))
        }
    }

    func testParsesSafeStockCodeRoute() {
        let route = URL(string: "stockmonitor://stock/600000").flatMap(StockMonitorRoute.init)
        XCTAssertEqual(route, .stock(code: "600000"))
        XCTAssertTrue(StockMonitorRoute.isSafeStockCode("000001"))
    }

    func testStockRouteUsesMonitorContextForWatchedCodes() {
        let route = StockMonitorRoute.stock(code: "600000")
        XCTAssertEqual(route.destination(forWatchCodes: ["600000", "000001"]),
                       .monitoredStock(code: "600000"))
    }

    func testUnlistedStockRouteResolvesToWatchlistEntry() {
        let route = StockMonitorRoute.stock(code: "600000")
        XCTAssertEqual(route.destination(forWatchCodes: ["000001"]),
                       .watchlistEntry(code: "600000"))
    }

    func testTabRouteResolvesToRequestedTab() {
        XCTAssertEqual(StockMonitorRoute.tab(.settings).destination(forWatchCodes: []),
                       .tab(.settings))
    }

    func testRejectsMalformedAndUnsafeRoutes() {
        let urls = [
            "stockmonitor://tab/unknown",
            "stockmonitor://stock/60000",
            "stockmonitor://stock/60000A",
            "stockmonitor://stock/１２３４５６",
            "https://stockmonitor.example/stock/600000",
            "stockmonitor://stock/600000?source=unknown"
        ]
        for rawURL in urls {
            XCTAssertNil(URL(string: rawURL).flatMap(StockMonitorRoute.init), rawURL)
        }
    }

    func testRejectsNonCanonicalAuthoritiesAndPaths() {
        let urls = [
            "stockmonitor:///tab/market",
            "stockmonitor://tab//market",
            "stockmonitor://tab/market/",
            "stockmonitor://tab/%6darket",
            "stockmonitor://user@tab/market",
            "stockmonitor://tab:443/market"
        ]
        for rawURL in urls {
            XCTAssertNil(URL(string: rawURL).flatMap(StockMonitorRoute.init), rawURL)
        }
    }
}

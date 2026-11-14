import XCTest
@testable import StockMonitorCore

final class MarketVenueMetadataTests: XCTestCase {
    func testRoutesSupportedEastmoneyFamiliesAndRejectsUnverified099() {
        XCTAssertEqual(MarketVenueCatalog.route(symbol: "600000", venue: .aShare)?.eastmoneySecID?.value, "1.600000")
        XCTAssertEqual(MarketVenueCatalog.route(symbol: "000001", venue: .aShare)?.eastmoneySecID?.value, "0.000001")
        XCTAssertEqual(MarketVenueCatalog.route(symbol: "00700", venue: .hkex)?.eastmoneySecID?.value, "116.00700")
        XCTAssertEqual(MarketVenueCatalog.route(symbol: "AAPL", venue: .nasdaq)?.eastmoneySecID?.value, "105.AAPL")
        XCTAssertEqual(MarketVenueCatalog.route(symbol: "SPY", venue: .nyse, securityKind: .etf)?.metadata.securityKind, .etf)
        XCTAssertNil(MarketVenueCatalog.route(symbol: "099001", venue: .aShare))
        XCTAssertNil(EastmoneySecIDPrefix(rawValue: "099"))
    }

    func testMetadataUsesVenueIANAZonesAndRegularWindows() {
        let aShareETF = MarketVenueCatalog.metadata(for: .aShare, securityKind: .etf)
        XCTAssertEqual(aShareETF.timeZoneIdentifier, "Asia/Shanghai")
        XCTAssertEqual(aShareETF.regularSessionWindows.count, 2)
        XCTAssertEqual(MarketVenueCatalog.metadata(for: .hkex).timeZoneIdentifier, "Asia/Hong_Kong")
        XCTAssertEqual(MarketVenueCatalog.metadata(for: .nyse).timeZoneIdentifier, "America/New_York")
    }

    func testNewYorkConversionReflectsDaylightSavingTime() throws {
        let winter = try XCTUnwrap(MarketVenueCatalog.date(from: DateComponents(year: 2026, month: 1, day: 15, hour: 14), in: TimeZone(secondsFromGMT: 0)!))
        let summer = try XCTUnwrap(MarketVenueCatalog.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 14), in: TimeZone(secondsFromGMT: 0)!))
        let zone = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(MarketVenueCatalog.localComponents(of: winter, in: zone).hour, 9)
        XCTAssertEqual(MarketVenueCatalog.localComponents(of: summer, in: zone).hour, 10)
    }

    func testWeekdaySessionIsUnknownWithoutVerifiedHolidayCalendar() throws {
        let metadata = MarketVenueCatalog.metadata(for: .nasdaq)
        let instant = try XCTUnwrap(MarketVenueCatalog.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 10), in: metadata.timeZone))
        XCTAssertEqual(MarketVenueCatalog.sessionStatus(instant, for: metadata), .unknownHoliday)
    }

    func testWeekendAndOutsideSessionAreNotReportedAsOpen() throws {
        let metadata = MarketVenueCatalog.metadata(for: .hkex)
        let saturday = try XCTUnwrap(MarketVenueCatalog.date(from: DateComponents(year: 2026, month: 7, day: 18, hour: 10), in: metadata.timeZone))
        let middayBreak = try XCTUnwrap(MarketVenueCatalog.date(from: DateComponents(year: 2026, month: 7, day: 17, hour: 12, minute: 30), in: metadata.timeZone))
        XCTAssertEqual(MarketVenueCatalog.sessionStatus(saturday, for: metadata), .closedWeekend)
        XCTAssertEqual(MarketVenueCatalog.sessionStatus(middayBreak, for: metadata), .closedOutsideRegularSession)
    }
}

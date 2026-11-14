import XCTest
@testable import StockMonitorCore

final class AppleNotificationAlertDeliveryTests: XCTestCase {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testEmptyUnreadSignalsProduceNoPayload() {
        XCTAssertNil(AlertNotificationCore.payload(for: []))
    }

    func testMultiplePendingAlertsBecomeOneDeterministicPayload() throws {
        let older = signal(id: firstID, title: "Older alert", detail: "Older detail", at: 100)
        let newer = signal(id: secondID, title: "Newer alert", detail: "Newer detail", at: 200)

        let payload = try XCTUnwrap(AlertNotificationCore.payload(for: [older, newer]))

        XCTAssertEqual(payload.identifier,
                       "alert-delivery-v1:\(secondID.uuidString.lowercased()),\(firstID.uuidString.lowercased())")
        XCTAssertEqual(payload.title, "Stock alerts (2)")
        XCTAssertEqual(payload.body, "Newer alert\nOlder alert")
        XCTAssertEqual(
            payload.userInfo[AlertNotificationCore.signalIDsKey],
            "\(secondID.uuidString.lowercased()),\(firstID.uuidString.lowercased())"
        )
        XCTAssertEqual(
            payload.userInfo[AlertNotificationCore.idempotencyKeyKey],
            payload.identifier
        )
        XCTAssertEqual(payload.actionIdentifiers, [
            AlertNotificationActionIdentifier.snooze30Minutes,
            AlertNotificationActionIdentifier.markRead
        ])
    }

    func testPayloadIsIndependentOfInputOrderAndDuplicateSignals() throws {
        let first = signal(id: firstID, title: "First", detail: "Detail", at: 100)
        let second = signal(id: secondID, title: "Second", detail: "Detail", at: 200)

        let left = try XCTUnwrap(AlertNotificationCore.payload(for: [first, second, first]))
        let right = try XCTUnwrap(AlertNotificationCore.payload(for: [second, first]))

        XCTAssertEqual(left, right)
    }

    func testSingleAlertUsesSignalTitleAndDetail() throws {
        let alert = signal(id: firstID, title: "Price crossed", detail: "600000 rose", at: 100)

        let payload = try XCTUnwrap(AlertNotificationCore.payload(for: [alert]))

        XCTAssertEqual(payload.title, "Price crossed")
        XCTAssertEqual(payload.body, "600000 rose")
    }

    func testActionIdentifiersAreStableAndDistinct() {
        XCTAssertNotEqual(
            AlertNotificationActionIdentifier.snooze30Minutes,
            AlertNotificationActionIdentifier.markRead
        )
        XCTAssertEqual(AlertNotificationActionIdentifier.snooze30Minutes,
                       "stock-monitor.alert.snooze-30-minutes")
        XCTAssertEqual(AlertNotificationActionIdentifier.markRead,
                       "stock-monitor.alert.mark-read")
    }

    private func signal(id: UUID, title: String, detail: String, at seconds: TimeInterval) -> AlertSignal {
        AlertSignal(id: id, code: "600000", ruleID: "test-rule", level: .warning,
                    title: title, detail: detail,
                    createdAt: Date(timeIntervalSince1970: seconds))
    }
}

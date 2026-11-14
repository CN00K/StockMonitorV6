import XCTest
@testable import StockMonitorCore

final class AlertDeliveryTests: XCTestCase {
    private let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
    private let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

    func testAggregationOrdersNewestFirstAndExposesStableIDs() throws {
        let older = signal(id: firstID, at: 100)
        let newer = signal(id: secondID, at: 200)

        let request = try XCTUnwrap(AlertDeliveryCore.request(for: [older, newer]))

        XCTAssertEqual(request.signals.map(\.id), [secondID, firstID])
        XCTAssertEqual(request.signalIDs, [secondID, firstID])
        XCTAssertEqual(request.idempotencyKey,
                       "alert-delivery-v1:\(secondID.uuidString.lowercased()),\(firstID.uuidString.lowercased())")
    }

    func testEqualTimestampsUseUUIDTieBreakerAndDuplicateIDsAreRemoved() throws {
        let first = signal(id: firstID, at: 100)
        let second = signal(id: secondID, at: 100)

        let request = try XCTUnwrap(AlertDeliveryCore.request(for: [second, first, first]))

        XCTAssertEqual(request.signalIDs, [firstID, secondID])
        XCTAssertEqual(request.signals.count, 2)
    }

    func testEmptyInputProducesNoRequest() {
        XCTAssertNil(AlertDeliveryCore.request(for: []))
    }

    func testSnoozeFactoryUsesExactlyThirtyMinutes() throws {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let command = AlertDeliveryCore.snooze30Minutes(for: firstID, from: reference)

        guard case let .snooze(signalID, until) = command else {
            return XCTFail("Expected a snooze command")
        }
        XCTAssertEqual(signalID, firstID)
        XCTAssertEqual(until, reference.addingTimeInterval(1_800))
    }

    func testActionFactoriesArePureAndAddressTheRequestedSignal() {
        XCTAssertEqual(AlertDeliveryCore.markRead(for: firstID), .markRead(signalID: firstID))
        XCTAssertEqual(
            AlertActionCommand.snooze30Minutes(for: firstID, from: Date(timeIntervalSince1970: 10)),
            .snooze(signalID: firstID, until: Date(timeIntervalSince1970: 1_810))
        )
    }

    func testIdempotencyKeyIsDeterministicRegardlessOfInputOrder() throws {
        let first = signal(id: firstID, at: 100)
        let second = signal(id: secondID, at: 200)

        let left = try XCTUnwrap(AlertDeliveryCore.request(for: [first, second]))
        let right = try XCTUnwrap(AlertDeliveryCore.request(for: [second, first]))

        XCTAssertEqual(left, right)
        XCTAssertEqual(left.idempotencyKey, right.idempotencyKey)
    }

    private func signal(id: UUID, at seconds: TimeInterval) -> AlertSignal {
        AlertSignal(id: id, code: "600000", ruleID: "test-rule", level: .warning,
                    title: "Test alert", detail: "Test detail",
                    createdAt: Date(timeIntervalSince1970: seconds))
    }
}

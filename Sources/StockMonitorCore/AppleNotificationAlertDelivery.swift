import Foundation

/// Stable identifiers used by the Apple notification adapter and its action handlers.
public enum AlertNotificationActionIdentifier {
    public static let snooze30Minutes = "stock-monitor.alert.snooze-30-minutes"
    public static let markRead = "stock-monitor.alert.mark-read"
}

/// The platform-neutral payload produced for one aggregated pending-alert notification.
/// Its userInfo values are strings so the payload can be encoded and handed to any
/// platform adapter without depending on UserNotifications types.
public struct AlertNotificationPayload: Codable, Sendable, Equatable {
    public let identifier: String
    public let title: String
    public let body: String
    public let userInfo: [String: String]
    public let actionIdentifiers: [String]

    public init(identifier: String, title: String, body: String,
                userInfo: [String: String], actionIdentifiers: [String]) {
        self.identifier = identifier
        self.title = title
        self.body = body
        self.userInfo = userInfo
        self.actionIdentifiers = actionIdentifiers
    }
}

/// Pure aggregation and payload construction for pending alert delivery.
public enum AlertNotificationCore {
    public static let categoryIdentifier = "stock-monitor.alert.category"
    public static let signalIDsKey = "stock-monitor.alert.signal-ids"
    public static let idempotencyKeyKey = "stock-monitor.alert.idempotency-key"

    /// Builds one deterministic notification payload for all pending signals.
    /// Ordering and duplicate removal are delegated to AlertDeliveryCore.
    public static func payload(for request: AlertDeliveryRequest) -> AlertNotificationPayload {
        let signals = request.signals
        let count = signals.count
        let title = count == 1 ? signals[0].title : "Stock alerts (\(count))"
        let body: String
        if count == 1 {
            body = signals[0].detail
        } else {
            body = signals.map(\.title).joined(separator: "\n")
        }

        return AlertNotificationPayload(
            identifier: request.idempotencyKey,
            title: title,
            body: body,
            userInfo: [
                signalIDsKey: request.signalIDs.map { $0.uuidString.lowercased() }.joined(separator: ","),
                idempotencyKeyKey: request.idempotencyKey
            ],
            actionIdentifiers: [
                AlertNotificationActionIdentifier.snooze30Minutes,
                AlertNotificationActionIdentifier.markRead
            ]
        )
    }

    public static func payload(for unreadSignals: [AlertSignal]) -> AlertNotificationPayload? {
        guard let request = AlertDeliveryCore.request(for: unreadSignals) else { return nil }
        return payload(for: request)
    }
}

#if canImport(UserNotifications)
import UserNotifications

/// Explicit permission boundary. Calling `deliver` never requests permission.
public protocol AlertNotificationPermissionBoundary: Sendable {
    func requestAuthorization() async throws -> Bool
}

/// Delivers the pure aggregated payload through UNUserNotificationCenter on Apple platforms.
/// The caller must explicitly invoke `requestAuthorization()` at an appropriate product boundary.
public final class AppleNotificationAlertDelivery: AlertDelivery, AlertNotificationPermissionBoundary, @unchecked Sendable {
    public let center: UNUserNotificationCenter

    public init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    public func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func deliver(_ request: AlertDeliveryRequest) async throws {
        let payload = AlertNotificationCore.payload(for: request)
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.categoryIdentifier = AlertNotificationCore.categoryIdentifier
        content.userInfo = payload.userInfo
        content.sound = .default

        let snooze = UNNotificationAction(
            identifier: AlertNotificationActionIdentifier.snooze30Minutes,
            title: "Snooze 30 minutes",
            options: []
        )
        let markRead = UNNotificationAction(
            identifier: AlertNotificationActionIdentifier.markRead,
            title: "Mark read",
            options: [.foreground]
        )
        let category = UNNotificationCategory(
            identifier: AlertNotificationCore.categoryIdentifier,
            actions: [snooze, markRead],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        let request = UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: nil
        )
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
#endif

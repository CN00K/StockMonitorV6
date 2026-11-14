import Foundation

/// A platform-neutral batch of unread alert signals ready for a delivery adapter.
/// Creating a request does not deliver it or change signal state.
public struct AlertDeliveryRequest: Codable, Sendable, Equatable {
    public let signals: [AlertSignal]
    public let idempotencyKey: String

    public var signalIDs: [UUID] { signals.map(\.id) }

    public init(signals: [AlertSignal], idempotencyKey: String) {
        self.signals = signals
        self.idempotencyKey = idempotencyKey
    }
}

/// A state-changing intent for an adapter to apply elsewhere.
/// The core only constructs commands; it does not execute them.
public enum AlertActionCommand: Codable, Sendable, Equatable {
    case markRead(signalID: UUID)
    case snooze(signalID: UUID, until: Date)

    /// Constructs a read command without performing the read.
    public static func markRead(for signalID: UUID) -> Self {
        .markRead(signalID: signalID)
    }

    /// Constructs a 30-minute snooze command using the supplied reference time.
    public static func snooze30Minutes(for signalID: UUID, from referenceDate: Date) -> Self {
        .snooze(signalID: signalID, until: referenceDate.addingTimeInterval(30 * 60))
    }
}

/// A delivery implementation supplied by an application boundary.
/// This module intentionally provides no notification, push, or network implementation.
public protocol AlertDelivery: Sendable {
    func deliver(_ request: AlertDeliveryRequest) async throws
}

/// Pure operations for turning unread signals into delivery intents.
public enum AlertDeliveryCore {
    /// Aggregates unread signals into one deterministic request, or nil for empty input.
    /// Signals are ordered newest-first, then by UUID for a deterministic tie-breaker.
    /// Duplicate IDs are removed, and the resulting ID list forms the idempotency key.
    public static func request(for unreadSignals: [AlertSignal]) -> AlertDeliveryRequest? {
        let ordered = unreadSignals
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt > rhs.createdAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            .reduce(into: [AlertSignal]()) { result, signal in
                guard !result.contains(where: { $0.id == signal.id }) else { return }
                result.append(signal)
            }

        guard !ordered.isEmpty else { return nil }
        let idempotencyKey = ordered
            .map { $0.id.uuidString.lowercased() }
            .joined(separator: ",")
        return AlertDeliveryRequest(signals: ordered, idempotencyKey: "alert-delivery-v1:\(idempotencyKey)")
    }

    public static func markRead(for signalID: UUID) -> AlertActionCommand {
        .markRead(for: signalID)
    }

    public static func snooze30Minutes(for signalID: UUID, from referenceDate: Date) -> AlertActionCommand {
        .snooze30Minutes(for: signalID, from: referenceDate)
    }
}

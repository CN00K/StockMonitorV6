import Foundation

public enum LiveTickStatusOperation: String, Codable, Sendable, Equatable {
    case tick
    case reconcile
}

public enum LiveTickDataStatus: String, Codable, Sendable, Equatable {
    case complete
    case partial
    case empty
}

public enum LiveReconcileOutcome: String, Codable, Sendable, Equatable {
    case success
    case failure
    case unknown
}

/// A bounded, body-free local record of one live tick or reconciliation attempt.
public struct LiveTickStatusRecord: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let recordedAt: Date
    public let operation: LiveTickStatusOperation
    public let dataStatus: LiveTickDataStatus
    public let requestedSymbols: Int
    public let returnedSymbols: Int
    public let missingSymbols: [String]
    public let reconcileOutcome: LiveReconcileOutcome

    public init(id: UUID = UUID(), recordedAt: Date, operation: LiveTickStatusOperation,
                dataStatus: LiveTickDataStatus, requestedSymbols: Int, returnedSymbols: Int,
                missingSymbols: [String] = [],
                reconcileOutcome: LiveReconcileOutcome = .unknown) {
        self.id = id
        self.recordedAt = recordedAt
        self.operation = operation
        self.dataStatus = dataStatus
        self.requestedSymbols = max(0, requestedSymbols)
        self.returnedSymbols = max(0, returnedSymbols)
        self.missingSymbols = Array(Set(missingSymbols)).sorted()
        self.reconcileOutcome = reconcileOutcome
    }
}

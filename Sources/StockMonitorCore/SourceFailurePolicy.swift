import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum SourceFailureKind: String, Codable, Sendable, Equatable {
    case transient
    case rateLimited
    case forbidden
    case malformedResponse
    case htmlChallenge
    case permanent

    public var isRetryable: Bool {
        switch self {
        case .transient, .rateLimited, .htmlChallenge, .malformedResponse: return true
        case .forbidden, .permanent: return false
        }
    }
}

public enum FailureGateState: String, Codable, Sendable, Equatable {
    case closed
    case open
    case halfOpen
}

public struct FailureGateDecision: Sendable, Equatable {
    public let allowed: Bool
    public let state: FailureGateState
    public let retryAt: Date?
    public let isProbe: Bool
    public let consecutiveFailures: Int
    public let failureKind: SourceFailureKind?

    public init(allowed: Bool, state: FailureGateState, retryAt: Date? = nil,
                isProbe: Bool = false, consecutiveFailures: Int = 0,
                failureKind: SourceFailureKind? = nil) {
        self.allowed = allowed
        self.state = state
        self.retryAt = retryAt
        self.isProbe = isProbe
        self.consecutiveFailures = consecutiveFailures
        self.failureKind = failureKind
    }

    public var canProceed: Bool { allowed }
    public var shouldRetry: Bool { allowed && state != .open }
}

public struct HTTPInspectionResult: Sendable, Equatable {
    public let statusCode: Int
    public let kind: SourceFailureKind?
    public let isSuccess: Bool
    public let retryable: Bool
    public let contentType: String?

    public init(statusCode: Int, kind: SourceFailureKind?, isSuccess: Bool,
                retryable: Bool, contentType: String?) {
        self.statusCode = statusCode
        self.kind = kind
        self.isSuccess = isSuccess
        self.retryable = retryable
        self.contentType = contentType
    }
}

public enum HTTPResponseInspector {
    public static func inspect(response: HTTPURLResponse, bodyData: Data? = nil) -> HTTPInspectionResult {
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return inspect(statusCode: response.statusCode, headers: headers, bodyData: bodyData)
    }

    public static func inspect(statusCode: Int, headers: [String: String] = [:], bodyData: Data?) -> HTTPInspectionResult {
        let text = bodyData.flatMap { String(data: $0, encoding: .utf8) }
        return inspect(statusCode: statusCode, headers: headers, body: text)
    }

    public static func inspect(statusCode: Int, headers: [String: String] = [:], body: String? = nil) -> HTTPInspectionResult {
        let contentType = headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        let normalizedContentType = contentType?.split(separator: ";", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let trimmed = body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lower = trimmed.lowercased()
        let html = lower.hasPrefix("<html") || lower.hasPrefix("<!doctype html") || normalizedContentType == "text/html"

        let kind: SourceFailureKind?
        if statusCode == 429 {
            kind = .rateLimited
        } else if statusCode == 403 {
            kind = .forbidden
        } else if (500...599).contains(statusCode) {
            kind = .transient
        } else if (400...499).contains(statusCode) {
            kind = .permanent
        } else if html {
            kind = .htmlChallenge
        } else if statusCode == 204 {
            kind = nil
        } else if normalizedContentType == "application/json" || normalizedContentType?.hasSuffix("+json") == true {
            kind = isValidJSON(trimmed) ? nil : .malformedResponse
        } else if (200...299).contains(statusCode) {
            kind = nil
        } else {
            kind = .transient
        }
        return HTTPInspectionResult(statusCode: statusCode, kind: kind, isSuccess: kind == nil && (200...299).contains(statusCode), retryable: kind?.isRetryable ?? false, contentType: normalizedContentType)
    }

    private static func isValidJSON(_ value: String) -> Bool {
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }
}

public actor SourceFailurePolicy {
    public static let defaultCircuitThreshold = 3
    public static let defaultCircuitDuration: TimeInterval = 15 * 60
    public static let defaultMaximumBackoff: TimeInterval = 60

    private struct State {
        var failures = 0
        var retryAt: Date?
        var circuit: FailureGateState = .closed
        var probeInFlight = false
        var lastKind: SourceFailureKind?
    }

    private var states: [String: State] = [:]
    private let now: @Sendable () -> Date
    private let jitter: @Sendable () -> Double
    private let threshold: Int
    private let circuitDuration: TimeInterval
    private let maximumBackoff: TimeInterval

    public init(now: @escaping @Sendable () -> Date = { Date() },
                jitter: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
                threshold: Int = SourceFailurePolicy.defaultCircuitThreshold,
                circuitDuration: TimeInterval = SourceFailurePolicy.defaultCircuitDuration,
                maximumBackoff: TimeInterval = SourceFailurePolicy.defaultMaximumBackoff) {
        self.now = now
        self.jitter = jitter
        self.threshold = max(1, threshold)
        self.circuitDuration = max(0, circuitDuration)
        self.maximumBackoff = max(0, maximumBackoff)
    }

    public func decision(for sourceID: String) -> FailureGateDecision {
        let current = now()
        var state = states[sourceID] ?? State()
        if state.circuit == .open, let retryAt = state.retryAt, current >= retryAt {
            state.circuit = .halfOpen
            state.probeInFlight = false
            states[sourceID] = state
        }
        if state.circuit == .open {
            return FailureGateDecision(allowed: false, state: .open, retryAt: state.retryAt, consecutiveFailures: state.failures, failureKind: state.lastKind)
        }
        if state.circuit == .halfOpen {
            guard !state.probeInFlight else {
                return FailureGateDecision(allowed: false, state: .halfOpen, retryAt: current, consecutiveFailures: state.failures, failureKind: state.lastKind)
            }
            state.probeInFlight = true
            states[sourceID] = state
            return FailureGateDecision(allowed: true, state: .halfOpen, isProbe: true, consecutiveFailures: state.failures, failureKind: state.lastKind)
        }
        if let retryAt = state.retryAt, current < retryAt {
            return FailureGateDecision(allowed: false, state: .closed, retryAt: retryAt,
                consecutiveFailures: state.failures, failureKind: state.lastKind)
        }
        if state.retryAt != nil {
            state.retryAt = nil
            states[sourceID] = state
        }
        return FailureGateDecision(allowed: true, state: .closed, retryAt: state.retryAt, consecutiveFailures: state.failures, failureKind: state.lastKind)
    }

    public func allow(sourceID: String) -> FailureGateDecision { decision(for: sourceID) }
    public func shouldAllow(sourceID: String) -> FailureGateDecision { decision(for: sourceID) }

    @discardableResult
    public func recordFailure(sourceID: String, kind: SourceFailureKind, at date: Date? = nil) -> FailureGateDecision {
        let current = date ?? now()
        var state = states[sourceID] ?? State()
        state.lastKind = kind
        state.probeInFlight = false
        if kind == .forbidden {
            state.failures = max(state.failures + 1, threshold)
            state.circuit = .open
            state.retryAt = current.addingTimeInterval(circuitDuration)
            states[sourceID] = state
            return FailureGateDecision(allowed: false, state: .open, retryAt: state.retryAt,
                consecutiveFailures: state.failures, failureKind: kind)
        }
        guard kind.isRetryable else {
            state.retryAt = nil
            state.circuit = .closed
            states[sourceID] = state
            return FailureGateDecision(allowed: false, state: .closed, consecutiveFailures: state.failures, failureKind: kind)
        }
        state.failures += 1
        if state.failures >= threshold {
            state.circuit = .open
            state.retryAt = current.addingTimeInterval(circuitDuration)
        } else {
            state.circuit = .closed
            let exponent = min(state.failures - 1, 6)
            let base = min(maximumBackoff, pow(2.0, Double(exponent)))
            let factor = 1 + max(-1, min(1, jitter() * 2 - 1)) * 0.20
            state.retryAt = current.addingTimeInterval(min(maximumBackoff, max(0, base * factor)))
        }
        states[sourceID] = state
        return FailureGateDecision(allowed: false, state: state.circuit, retryAt: state.retryAt, consecutiveFailures: state.failures, failureKind: kind)
    }

    public func recordSuccess(sourceID: String) {
        states[sourceID] = State()
    }

    public func reset(sourceID: String) { recordSuccess(sourceID: sourceID) }
    public func consecutiveFailures(for sourceID: String) -> Int { states[sourceID]?.failures ?? 0 }
}

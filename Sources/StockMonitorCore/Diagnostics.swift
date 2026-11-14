import Foundation

/// Small, allowlisted provider health projection. It intentionally excludes URLs,
/// request/response data, holdings, symbols, credentials, and user content.
public struct DiagnosticSourceStatus: Codable, Sendable, Equatable {
    public let sourceID: String
    public let fetchedAt: Date
    public let providerTimestamp: Date?
    public let requestedCount: Int
    public let returnedCount: Int
    public let requestCount: Int
    public let failed: Bool

    public init(sourceID: String, fetchedAt: Date, providerTimestamp: Date? = nil,
                requestedCount: Int = 0, returnedCount: Int = 0, requestCount: Int = 0,
                failed: Bool = false) {
        self.sourceID = Self.capped(sourceID, 128)
        self.fetchedAt = fetchedAt
        self.providerTimestamp = providerTimestamp
        self.requestedCount = max(0, requestedCount)
        self.returnedCount = max(0, returnedCount)
        self.requestCount = max(0, requestCount)
        self.failed = failed
    }

    public init(_ status: SourceStatus) {
        self.init(sourceID: status.sourceID, fetchedAt: status.fetchedAt,
                  providerTimestamp: status.providerTimestamp,
                  requestedCount: status.requestedCount, returnedCount: status.returnedCount,
                  requestCount: status.requestCount, failed: status.error != nil)
    }

    private static func capped(_ value: String, _ limit: Int) -> String {
        String(value.prefix(limit))
    }
}

/// Operational aggregate metrics only; no business/event payloads are accepted.
public struct DiagnosticHealthMetrics: Codable, Sendable, Equatable {
    public let windowStart: Date
    public let windowEnd: Date
    public let providerSuccesses: Int
    public let providerAttempts: Int
    public let filterKept: Int
    public let filterTotal: Int
    public let enrichedDecisions: Int
    public let ruleOrSkippedDecisions: Int

    public init(windowStart: Date, windowEnd: Date, providerSuccesses: Int = 0,
                providerAttempts: Int = 0, filterKept: Int = 0, filterTotal: Int = 0,
                enrichedDecisions: Int = 0, ruleOrSkippedDecisions: Int = 0) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.providerSuccesses = max(0, providerSuccesses)
        self.providerAttempts = max(0, providerAttempts)
        self.filterKept = max(0, filterKept)
        self.filterTotal = max(0, filterTotal)
        self.enrichedDecisions = max(0, enrichedDecisions)
        self.ruleOrSkippedDecisions = max(0, ruleOrSkippedDecisions)
    }

    public init(_ snapshot: SourceHealthSnapshot) {
        self.init(windowStart: snapshot.from, windowEnd: snapshot.through,
                  providerSuccesses: snapshot.p1Successes, providerAttempts: snapshot.p1Attempts,
                  filterKept: snapshot.filterKept, filterTotal: snapshot.filterTotal,
                  enrichedDecisions: snapshot.llmEnrichedDecisions,
                  ruleOrSkippedDecisions: snapshot.ruleOrSkippedDecisions)
    }
}

public struct DiagnosticBundleMetadata: Codable, Sendable, Equatable {
    public let schema: String
    public let schemaVersion: Int
    public let generatedAt: Date
    public let appVersion: String?

    public init(schema: String = "stock-monitor-diagnostics", schemaVersion: Int = 1,
                generatedAt: Date, appVersion: String? = nil) {
        self.schema = String(schema.prefix(96))
        self.schemaVersion = max(1, schemaVersion)
        self.generatedAt = generatedAt
        self.appVersion = appVersion.map { String($0.prefix(64)) }
    }
}

/// The complete export surface. Keep additions explicit: this is a privacy boundary.
public struct DiagnosticBundle: Codable, Sendable, Equatable {
    public let metadata: DiagnosticBundleMetadata
    public let sourceStatuses: [DiagnosticSourceStatus]
    public let healthMetrics: DiagnosticHealthMetrics?

    public init(metadata: DiagnosticBundleMetadata, sourceStatuses: [DiagnosticSourceStatus] = [],
                healthMetrics: DiagnosticHealthMetrics? = nil) {
        self.metadata = metadata
        self.sourceStatuses = Array(sourceStatuses.sorted { $0.sourceID < $1.sourceID }.prefix(64))
        self.healthMetrics = healthMetrics
    }
}

public enum DiagnosticRedactor {
    public static let replacement = "[REDACTED]"
    private static let sensitiveNames = ["authorization", "proxy-authorization", "cookie", "set-cookie", "token", "secret", "password", "passwd", "api-key", "apikey", "key", "credential", "credentials", "signature", "access-token", "refresh-token", "user", "username"]

    /// Redacts URL userinfo and query/fragment values without performing network work.
    public static func redact(url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return redact(String(url.absoluteString))
        }
        components.user = nil
        components.password = nil
        components.queryItems = components.queryItems?.map { item in
            URLQueryItem(name: item.name, value: isSensitive(item.name) ? replacement : item.value.map { redactPatterns($0) })
        }
        components.fragment = components.fragment.map { _ in replacement }
        return String(redactPatterns(components.string ?? url.absoluteString).prefix(512))
    }

    /// Bounded text redaction for log fields and error descriptions.
    public static func redact(_ value: String, maxLength: Int = 512) -> String {
        let output = redactPatterns(value)
        if let url = URL(string: output), url.scheme != nil {
            return String(redact(url: url).prefix(max(0, maxLength)))
        }
        return String(output.prefix(max(0, maxLength)))
    }

    public static func redact(fields: [String: String], maxFields: Int = 32, maxValueLength: Int = 256) -> [String: String] {
        var result: [String: String] = [:]
        for key in fields.keys.sorted().prefix(maxFields) {
            result[String(key.prefix(64))] = isSensitive(key) ? replacement : redact(fields[key] ?? "", maxLength: maxValueLength)
        }
        return result
    }

    private static func isSensitive(_ name: String) -> Bool {
        let normalized = name.lowercased().replacingOccurrences(of: "_", with: "-")
        return sensitiveNames.contains { normalized == $0 || normalized.contains($0) }
    }

    private static func redactPatterns(_ value: String) -> String {
        let patterns: [(String, String)] = [
            (#"(?i)(authorization|proxy-authorization)\s*[:=]\s*(?:Bearer\s+)?[^\s,;]+"#, "$1=\(replacement)"),
            (#"(?i)(cookie|set-cookie|api[-_]?key|access[-_]?token|refresh[-_]?token|token|password|passwd|secret|credential|signature)\s*[:=]\s*[^\s,;]+"#, "$1=\(replacement)"),
            (#"(?i)(https?://)[^/\s@]+@"#, "$1\(replacement)@")
        ]
        var output = value
        for (pattern, replacementText) in patterns {
            output = output.replacingOccurrences(of: pattern, with: replacementText, options: .regularExpression)
        }
        return output
    }
}

public enum DiagnosticLogLevel: String, Codable, Sendable { case debug, info, warning, error }

public struct DiagnosticLogEvent: Codable, Sendable, Equatable {
    public let level: DiagnosticLogLevel
    public let message: String
    public let fields: [String: String]
    public let timestamp: Date

    public init(level: DiagnosticLogLevel, message: String, fields: [String: String] = [:], timestamp: Date = Date()) {
        self.level = level
        self.message = DiagnosticRedactor.redact(message)
        self.fields = DiagnosticRedactor.redact(fields: fields)
        self.timestamp = timestamp
    }
}

public protocol DiagnosticLogger: Sendable {
    func log(_ event: DiagnosticLogEvent)
}

public struct NoopDiagnosticLogger: DiagnosticLogger, Sendable {
    public init() {}
    public func log(_ event: DiagnosticLogEvent) {}
}

#if canImport(os)
import os
/// Apple sink; all content is redacted before reaching `os.Logger`.
public struct OSLogDiagnosticLogger: DiagnosticLogger, Sendable {
    private let logger: Logger
    public init(subsystem: String = "StockMonitor", category: String = "Diagnostics") {
        logger = Logger(subsystem: subsystem, category: category)
    }
    public func log(_ event: DiagnosticLogEvent) {
        let fields = event.fields.keys.sorted().map { "\($0)=\(event.fields[$0] ?? "")" }.joined(separator: " ")
        let line = DiagnosticRedactor.redact(fields.isEmpty ? event.message : "\(event.message) \(fields)")
        switch event.level {
        case .debug: logger.debug("\(line, privacy: .public)")
        case .info: logger.info("\(line, privacy: .public)")
        case .warning: logger.warning("\(line, privacy: .public)")
        case .error: logger.error("\(line, privacy: .public)")
        }
    }
}
#endif

public enum DiagnosticBundleExporter {
    public static func encode(_ bundle: DiagnosticBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(bundle)
    }

    /// Deterministic JSON export as an in-memory local artifact.
    public static func export(_ bundle: DiagnosticBundle) throws -> Data {
        try encode(bundle)
    }

    @discardableResult
    public static func write(_ bundle: DiagnosticBundle, to url: URL) throws -> URL {
        let data = try encode(bundle)
        try data.write(to: url, options: [.atomic])
        return url
    }

    /// Deterministic JSON export to a caller-selected local URL. No network or
    /// implicit directory is involved.
    @discardableResult
    public static func export(_ bundle: DiagnosticBundle, to url: URL) throws -> URL {
        try write(bundle, to: url)
    }
}

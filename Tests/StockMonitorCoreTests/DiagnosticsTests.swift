import Foundation
import XCTest
@testable import StockMonitorCore

final class DiagnosticsTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_700_000_000)

    func testURLRedactionRemovesUserinfoAndSensitiveQueryValues() throws {
        let url = try XCTUnwrap(URL(string: "https://alice:pw@example.com/v1?q=hello&api_key=super-secret&token=abc#fragment"))
        let redacted = DiagnosticRedactor.redact(url: url)
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("pw"))
        XCTAssertFalse(redacted.contains("super-secret"))
        XCTAssertFalse(redacted.contains("abc"))
        XCTAssertTrue(redacted.contains("api_key="))
        XCTAssertTrue(redacted.contains("%5BREDACTED%5D") || redacted.contains("[REDACTED]"))
    }

    func testTextAndFieldsAreBoundedAndSensitiveFieldsNeverPassThrough() {
        let text = DiagnosticRedactor.redact("Authorization: Bearer top-secret password=hunter2 https://u:p@example.com")
        XCTAssertFalse(text.contains("top-secret"))
        XCTAssertFalse(text.contains("hunter2"))
        XCTAssertFalse(text.contains("u:p@"))
        XCTAssertLessThanOrEqual(text.count, 512)

        let fields = DiagnosticRedactor.redact(fields: [
            "apiKey": "key-value", "safe": String(repeating: "x", count: 400)
        ], maxFields: 1, maxValueLength: 20)
        XCTAssertEqual(fields.count, 1)
        XCTAssertEqual(fields["apiKey"], "[REDACTED]")
    }

    func testBundleContainsOnlyExplicitAllowlistedFieldsAndIsDeterministic() throws {
        let source = DiagnosticSourceStatus(sourceID: "z-source", fetchedAt: date, providerTimestamp: date,
                                            requestedCount: 4, returnedCount: 3, requestCount: 1)
        let bundle = DiagnosticBundle(
            metadata: DiagnosticBundleMetadata(generatedAt: date, appVersion: "1.2.3"),
            sourceStatuses: [source],
            healthMetrics: DiagnosticHealthMetrics(windowStart: date, windowEnd: date,
                                                   providerSuccesses: 2, providerAttempts: 2))
        let first = try DiagnosticBundleExporter.encode(bundle)
        let second = try DiagnosticBundleExporter.encode(bundle)
        XCTAssertEqual(first, second)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["healthMetrics", "metadata", "sourceStatuses"])
        XCTAssertNil(object["holdings"])
        XCTAssertNil(object["apiKey"])
        XCTAssertNil(object["headers"])
        XCTAssertNil(object["body"])
        let sourceObject = try XCTUnwrap((object["sourceStatuses"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(sourceObject.keys), ["failed", "fetchedAt", "providerTimestamp", "requestCount", "requestedCount", "returnedCount", "sourceID"])
    }

    func testSourceStatusProjectionDropsErrorTextAndHealthProjectionIsBounded() {
        let status = SourceStatus(sourceID: "provider", fetchedAt: date,
                                  requestedCount: -1, returnedCount: -2, requestCount: -3,
                                  error: "Authorization: secret")
        let projection = DiagnosticSourceStatus(status)
        XCTAssertTrue(projection.failed)
        XCTAssertEqual(projection.requestedCount, 0)
        XCTAssertEqual(projection.returnedCount, 0)
        XCTAssertEqual(projection.requestCount, 0)

        let snapshot = SourceHealthSnapshot(from: date, through: date,
                                            p1Successes: -1, p1Attempts: -2,
                                            filterKept: -3, filterTotal: -4,
                                            llmEnrichedDecisions: -5,
                                            ruleOrSkippedDecisions: -6)
        let metrics = DiagnosticHealthMetrics(snapshot)
        XCTAssertEqual(metrics.providerSuccesses, 0)
        XCTAssertEqual(metrics.ruleOrSkippedDecisions, 0)
    }

    func testStructuredLogEventRedactsMessageAndFields() {
        let event = DiagnosticLogEvent(level: .error,
            message: "request failed token=do-not-log",
            fields: ["Authorization": "Bearer do-not-log", "source": "fixture"])
        XCTAssertFalse(event.message.contains("do-not-log"))
        XCTAssertEqual(event.fields["Authorization"], "[REDACTED]")
        XCTAssertEqual(event.fields["source"], "fixture")
        NoopDiagnosticLogger().log(event)
    }
}

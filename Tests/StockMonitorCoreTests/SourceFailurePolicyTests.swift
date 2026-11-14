import XCTest
@testable import StockMonitorCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class SourceFailurePolicyTests: XCTestCase {
    func testBackoffIsMonotonicCappedAndJittered() async {
        let clock = LockedDate(Date(timeIntervalSince1970: 0))
        let policy = SourceFailurePolicy(now: { clock.value }, jitter: { 0.5 }, threshold: 99)
        let first = await policy.recordFailure(sourceID: "a", kind: .transient)
        let second = await policy.recordFailure(sourceID: "a", kind: .transient)
        XCTAssertEqual(try XCTUnwrap(first.retryAt).timeIntervalSince1970, 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(second.retryAt).timeIntervalSince1970, 2, accuracy: 0.0001)
        var latest = second
        for _ in 0..<8 { latest = await policy.recordFailure(sourceID: "a", kind: .transient) }
        XCTAssertEqual(try XCTUnwrap(latest.retryAt).timeIntervalSince1970, 60, accuracy: 0.0001)
    }

    func testHTTPClassificationAndHTMLChallenge() {
        XCTAssertEqual(HTTPResponseInspector.inspect(statusCode: 429).kind, .rateLimited)
        XCTAssertEqual(HTTPResponseInspector.inspect(statusCode: 403).kind, .forbidden)
        XCTAssertEqual(HTTPResponseInspector.inspect(statusCode: 200, headers: ["Content-Type": "text/html"], body: "ok").kind, .htmlChallenge)
        XCTAssertEqual(HTTPResponseInspector.inspect(statusCode: 200, body: "<!doctype html><body>x").kind, .htmlChallenge)
        XCTAssertEqual(HTTPResponseInspector.inspect(statusCode: 200, headers: ["Content-Type": "application/json"], body: "not json").kind, .malformedResponse)
    }

    func testQuoteSourceHTTPValidationCarriesRateLimitForbiddenAndHTMLKinds() throws {
        let url = URL(string: "https://example.invalid/quote")!
        func failure(_ status: Int, _ headers: [String: String], _ data: Data,
                     decodedText: String? = nil) throws -> SourceFailureKind {
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: status,
                httpVersion: "HTTP/1.1", headerFields: headers))
            XCTAssertThrowsError(try QuoteSourceError.validateHTTPResponse(response, data: data,
                decodedText: decodedText)) { error in
                guard case QuoteSourceError.responseFailure(_, let kind) = error else {
                    return XCTFail("Expected a classified response failure, got \(error)")
                }
                XCTAssertEqual(kind, HTTPResponseInspector.inspect(statusCode: status,
                    headers: headers, body: decodedText ?? String(data: data, encoding: .utf8)).kind)
            }
            return HTTPResponseInspector.inspect(statusCode: status, headers: headers,
                body: decodedText ?? String(data: data, encoding: .utf8)).kind!
        }
        XCTAssertEqual(try failure(429, [:], Data()), .rateLimited)
        XCTAssertEqual(try failure(403, [:], Data()), .forbidden)
        XCTAssertEqual(try failure(200, ["Content-Type": "text/plain"], Data([0xff]),
            decodedText: "<html>blocked</html>"), .htmlChallenge)
        XCTAssertEqual(try failure(200, ["Content-Type": "application/json"], Data("bad".utf8)),
            .malformedResponse)
    }

    func testThreeFailuresOpenCircuitAndHalfOpenAllowsOnlyOneProbe() async {
        let clock = LockedDate(Date(timeIntervalSince1970: 0))
        let policy = SourceFailurePolicy(now: { clock.value }, jitter: { 0.5 })
        _ = await policy.recordFailure(sourceID: "a", kind: .transient)
        _ = await policy.recordFailure(sourceID: "a", kind: .transient)
        let opened = await policy.recordFailure(sourceID: "a", kind: .transient)
        XCTAssertEqual(opened.state, .open)
        let blocked = await policy.decision(for: "a")
        XCTAssertFalse(blocked.allowed)
        clock.value = opened.retryAt!
        let probe = await policy.decision(for: "a")
        let second = await policy.decision(for: "a")
        XCTAssertTrue(probe.allowed)
        XCTAssertTrue(probe.isProbe)
        XCTAssertFalse(second.allowed)
    }

    func testSuccessResetsAndPermanentDoesNotRetry() async {
        let policy = SourceFailurePolicy(jitter: { 0.5 })
        _ = await policy.recordFailure(sourceID: "a", kind: .transient)
        await policy.recordSuccess(sourceID: "a")
        let failures = await policy.consecutiveFailures(for: "a")
        let resetDecision = await policy.decision(for: "a")
        XCTAssertEqual(failures, 0)
        XCTAssertTrue(resetDecision.allowed)
        let permanent = await policy.recordFailure(sourceID: "b", kind: .permanent)
        XCTAssertFalse(permanent.allowed)
        XCTAssertNil(permanent.retryAt)
        let permanentDecision = await policy.decision(for: "b")
        XCTAssertTrue(permanentDecision.allowed)
    }

    func testInspectorResultDoesNotCarryURLOrBody() {
        let result = HTTPResponseInspector.inspect(statusCode: 500, headers: ["Content-Type": "text/plain"], body: "https://secret.example/?token=abc PRIVATE BODY")
        let description = String(describing: result)
        XCTAssertFalse(description.contains("secret.example"))
        XCTAssertFalse(description.contains("PRIVATE BODY"))
        XCTAssertFalse(description.contains("token=abc"))
    }
}

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date
    init(_ date: Date) { stored = date }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

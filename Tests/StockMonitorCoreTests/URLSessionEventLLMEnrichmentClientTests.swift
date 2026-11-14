import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StockMonitorCore

final class URLSessionEventLLMEnrichmentClientTests: XCTestCase {
    private let endpoint = URL(string: "https://llm.example.test/v1/chat/completions")!
    private let key = "transient-secret-key"

    func testBuildsJSONOnlyChatCompletionRequestAndParsesContent() async throws {
        let transport = RecordingTransport(response: response(content: #"{"sectors":["银行"],"stockCodes":["600000"],"impactScope":"stock","priority":4}"#))
        let client = try URLSessionEventLLMEnrichmentClient(endpoint: endpoint, modelID: "test-model", transport: transport)
        let result = try await client.enrich(EventLLMEnrichmentRequest(event: event(), apiKey: key))

        XCTAssertEqual(result, EventLLMEnrichment(sectors: ["银行"], stockCodes: ["600000"],
            impactScope: .stock, priority: 4, promptTokenCount: 12,
            completionTokenCount: 7, totalTokenCount: 19))
        XCTAssertEqual(result.promptTokenCount, 12)
        XCTAssertEqual(result.completionTokenCount, 7)
        XCTAssertEqual(result.totalTokenCount, 19)
        let request = try XCTUnwrap(transport.request)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.url?.query)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "test-model")
        XCTAssertEqual(object["temperature"] as? Int, 0)
        let format = try XCTUnwrap(object["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["name"] as? String, "event_enrichment")
        XCTAssertEqual(schema["strict"] as? Bool, true)
        XCTAssertNotNil(schema["schema"] as? [String: Any])
    }

    func testRejectsStatusAndMalformedOrOutOfRangeResponses() async throws {
        for response in [
            EventHTTPResponse(data: Data(), statusCode: 401, contentType: nil),
            response(content: #"{"choices":[]}"#),
            response(content: #"{"choices":[{"message":{"content":"not-json"}}]}"#),
            response(content: #"{"choices":[{"message":{"content":"{"sectors":["x"],"stockCodes":[],"impactScope":null,"priority":6}"}}]}"#),
            response(content: #"{"choices":[{"message":{"content":"{"sectors":["x"],"stockCodes":["123"],"impactScope":null,"priority":null}"}}]}"#)
        ] {
            let transport = RecordingTransport(response: response)
            let client = try URLSessionEventLLMEnrichmentClient(endpoint: endpoint, modelID: "model", transport: transport)
            do {
                _ = try await client.enrich(EventLLMEnrichmentRequest(event: event(), apiKey: key))
                XCTFail("expected invalid response")
            } catch let error as URLSessionEventLLMEnrichmentClient.Error {
                XCTAssertNotEqual(error, .transport)
                XCTAssertFalse(error.localizedDescription.contains(key))
            }
        }
    }

    func testEndpointAndModelAreExplicitAndKeyNeverAppearsInErrors() {
        XCTAssertThrowsError(try URLSessionEventLLMEnrichmentClient(endpoint: URL(string: "http://llm.example.test")!, modelID: "model", transport: RecordingTransport(response: response(content: "{}"))))
        XCTAssertThrowsError(try URLSessionEventLLMEnrichmentClient(endpoint: URL(string: "https://llm.example.test/path?api_key=secret")!, modelID: "model", transport: RecordingTransport(response: response(content: "{}"))))
        XCTAssertThrowsError(try URLSessionEventLLMEnrichmentClient(endpoint: endpoint, modelID: "   ", transport: RecordingTransport(response: response(content: "{}"))))
    }

    func testEnricherPolicyAndKeyProviderGateTransport() async throws {
        let transport = RecordingTransport(response: response(content: "{}"))
        let client = try URLSessionEventLLMEnrichmentClient(endpoint: endpoint, modelID: "model", transport: transport)
        let disabled = EventLLMEnricher(client: client, config: .disabled)
        _ = try await disabled.enrich([event()])
        XCTAssertNil(transport.request)

        let noKey = EventLLMEnricher(client: client,
            config: EventLLMEnrichmentConfig(enabled: true, keyProvider: EmptyKeyProvider()))
        _ = try await noKey.enrich([event()])
        XCTAssertNil(transport.request)
    }

    func testCancellationPropagatesFromTransport() async throws {
        let transport = BlockingTransport()
        let client = try URLSessionEventLLMEnrichmentClient(endpoint: endpoint, modelID: "model", transport: transport)
        let task = Task {
            try await client.enrich(EventLLMEnrichmentRequest(event: event(), apiKey: key))
        }
        transport.started.wait()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertTrue(transport.wasCancelled)
        }
    }

    private func event() -> MarketEvent {
        MarketEvent(sourceID: "gov", title: "政策事件", body: "内容")
    }

    private func response(content: String) -> EventHTTPResponse {
        let envelope = #"{"choices":[{"message":{"content":"CONTENT"}}],"usage":{"prompt_tokens":12,"completion_tokens":7,"total_tokens":19}}"#.replacingOccurrences(of: "CONTENT", with: content.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))
        return EventHTTPResponse(data: Data(envelope.utf8), statusCode: 200, contentType: "application/json")
    }
}

private final class RecordingTransport: EventLLMHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let result: EventHTTPResponse
    private var storedRequest: URLRequest?
    var request: URLRequest? { lock.withLock { storedRequest } }

    init(response: EventHTTPResponse) { result = response }

    func send(_ request: URLRequest) async throws -> EventHTTPResponse {
        lock.withLock { storedRequest = request }
        return result
    }
}

private struct EmptyKeyProvider: EventLLMAPIKeyProvider {
    func apiKey() async -> String? { nil }
}

private final class BlockingTransport: EventLLMHTTPTransport, @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    private(set) var wasCancelled = false

    func send(_ request: URLRequest) async throws -> EventHTTPResponse {
        started.signal()
        do {
            try await Task.sleep(nanoseconds: 60_000_000_000)
            throw URLSessionEventLLMEnrichmentClient.Error.transport
        } catch is CancellationError {
            wasCancelled = true
            throw CancellationError()
        }
    }
}

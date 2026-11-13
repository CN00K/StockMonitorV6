import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest
@testable import StockMonitorCore

final class AnalystFlowTests: XCTestCase {
    func testValidContractUsesOfflineFakeAndCompletesSupervisorSpecialistsAndRefinement() async throws {
        let transport = FixtureAnalystTransport(mode: .valid)
        let analyst = OnDemandAnalyst(transport: transport)
        let result = try await analyst.analyze(context: fixtureContext(), configuration: configuration(), apiKey: "ephemeral")
        XCTAssertEqual(result.signal, "持有")
        XCTAssertEqual(result.confidence, 0.8, accuracy: 0.0001)
        XCTAssertEqual(result.scores.technical, 72, accuracy: 0.0001)
        XCTAssertEqual(result.technical, "技术面：证据充分")
        let count = await transport.requestCount
        XCTAssertEqual(count, 6)
        let strictCount = await transport.strictSchemaRequestCount
        let authorizedCount = await transport.authorizationRequestCount
        let leaked = await transport.credentialFoundInBody
        XCTAssertEqual(strictCount, 6)
        XCTAssertEqual(authorizedCount, 6)
        XCTAssertFalse(leaked)
    }

    func testMissingAndExtraKeysAreRejectedOffline() async {
        for mode in [FixtureAnalystTransport.Mode.missingKey, .extraKey] {
            let analyst = OnDemandAnalyst(transport: FixtureAnalystTransport(mode: mode))
            do {
                _ = try await analyst.analyze(context: fixtureContext(), configuration: configuration(), apiKey: "ephemeral")
                XCTFail("Expected strict-key validation failure for \(mode)")
            } catch let error as OnDemandAnalystError {
                XCTAssertEqual(error, .validationFailed)
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testInvalidRangesAreRejectedOffline() async {
        let analyst = OnDemandAnalyst(transport: FixtureAnalystTransport(mode: .invalidRange))
        do {
            _ = try await analyst.analyze(context: fixtureContext(), configuration: configuration(), apiKey: "ephemeral")
            XCTFail("Expected range validation failure")
        } catch let error as OnDemandAnalystError {
            XCTAssertEqual(error, .validationFailed)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnsafeEndpointAndOversizedContextAreRejectedBeforeTransport() async {
        let transport = FixtureAnalystTransport(mode: .valid)
        let analyst = OnDemandAnalyst(transport: transport)
        do {
            _ = try await analyst.analyze(context: fixtureContext(),
                configuration: OnDemandAnalystConfiguration(
                    endpoint: URL(string: "https://example.invalid/v1/chat/completions?token=not-allowed")!,
                    modelID: "fixture"), apiKey: "ephemeral")
            XCTFail("Query parameters are not allowed in provider URLs")
        } catch let error as OnDemandAnalystError {
            XCTAssertEqual(error, .invalidConfiguration)
        } catch { XCTFail("Unexpected error: \(error)") }

        let history = (0..<61).map { index in
            AnalystPricePoint(timestamp: Date(timeIntervalSince1970: Double(index)), close: 10)
        }
        do {
            _ = try await analyst.analyze(context: AnalystContext(stock: fixtureContext().stock, history: history),
                configuration: configuration(), apiKey: "ephemeral")
            XCTFail("Context over the hard history cap should not be sent")
        } catch let error as OnDemandAnalystError {
            XCTAssertEqual(error, .invalidContext)
        } catch { XCTFail("Unexpected error: \(error)") }
        let count = await transport.requestCount
        XCTAssertEqual(count, 0)
    }

    private func configuration() -> OnDemandAnalystConfiguration {
        OnDemandAnalystConfiguration(endpoint: URL(string: "https://example.invalid/v1/chat/completions")!, modelID: "fixture")
    }

    private func fixtureContext() -> AnalystContext {
        AnalystContext(stock: AnalystStockFacts(code: "600000", name: "测试股", currentPrice: 10.2,
                                                previousClose: 10, open: 10.1, high: 10.3, low: 10,
                                                volume: 1000), history: [], events: [])
    }
}

private actor FixtureAnalystTransport: AnalystTransport {
    enum Mode: Sendable, Equatable { case valid, missingKey, extraKey, invalidRange }
    let mode: Mode
    private(set) var requestCount = 0
    private(set) var strictSchemaRequestCount = 0
    private(set) var authorizationRequestCount = 0
    private(set) var credentialFoundInBody = false

    init(mode: Mode) { self.mode = mode }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requestCount += 1
        let requestData = request.httpBody ?? Data()
        if String(data: requestData, encoding: .utf8)?.contains("ephemeral") == true { credentialFoundInBody = true }
        if request.value(forHTTPHeaderField: "Authorization") == "Bearer ephemeral" { authorizationRequestCount += 1 }
        let body = (try? JSONSerialization.jsonObject(with: requestData) as? [String: Any]) ?? [:]
        let format = body["response_format"] as? [String: Any]
        let jsonSchema = format?["json_schema"] as? [String: Any]
        let schema = jsonSchema?["schema"] as? [String: Any]
        if format?["type"] as? String == "json_schema", jsonSchema?["strict"] as? Bool == true,
           schema?["additionalProperties"] as? Bool == false { strictSchemaRequestCount += 1 }
        let messages = body["messages"] as? [[String: Any]] ?? []
        let system = messages.first?["content"] as? String ?? ""
        let content: [String: Any]
        if system.contains("supervisor") {
            content = ["signal": "持有", "confidence": 0.8, "summary": "基于已给证据，风险为中性。", "risk": "风险：信息有限"]
        } else if system.contains("specialist") {
            content = ["score": mode == .invalidRange ? 101 : 72, "narrative": "证据充分"]
        } else {
            content = [
                "signal": "持有", "confidence": 0.8, "target_price": NSNull(), "stop_loss_price": 9.5,
                "scores": ["technical": 72, "fundamental": 68, "sentiment": 60, "risk": 45],
                "summary": "基于已给证据，风险为中性。", "technical": "技术面：证据充分",
                "fundamental": "基本面：资料有限", "sentiment": "情绪面：资料有限"
            ]
        }
        var response = content
        switch mode {
        case .missingKey: response.removeValue(forKey: "narrative")
        case .extraKey: response["unexpected"] = true
        case .valid, .invalidRange: break
        }
        let contentData = try JSONSerialization.data(withJSONObject: response)
        let envelope = try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": String(data: contentData, encoding: .utf8)!]]]])
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        return (envelope, http)
    }
}

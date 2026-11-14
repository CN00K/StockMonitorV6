import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Transport boundary used by the OpenAI-compatible client. Production uses URLSession;
/// tests can inject a deterministic transport without making network requests.
public protocol EventLLMHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> EventHTTPResponse
}

public struct URLSessionEventLLMHTTPTransport: EventLLMHTTPTransport, Sendable {
    public init() {}

    public func send(_ request: URLRequest) async throws -> EventHTTPResponse {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw URLSessionEventLLMEnrichmentClient.Error.nonHTTPResponse
            }
            return EventHTTPResponse(data: data, statusCode: httpResponse.statusCode,
                                     contentType: httpResponse.value(forHTTPHeaderField: "Content-Type"))
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLSessionEventLLMEnrichmentClient.Error {
            throw error
        } catch {
            throw URLSessionEventLLMEnrichmentClient.Error.transport
        }
    }
}

/// A bounded OpenAI-compatible chat-completions client for event metadata extraction.
/// The API key is read from each request and is never retained by this client.
public struct URLSessionEventLLMEnrichmentClient: EventLLMEnrichmentClient, Sendable {
    public enum Error: Swift.Error, LocalizedError, Equatable, Sendable {
        case invalidEndpoint
        case emptyModelID
        case nonHTTPResponse
        case httpStatus(Int)
        case responseTooLarge
        case invalidResponse
        case transport

        public var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "LLM endpoint must be HTTPS and must not contain a query or fragment"
            case .emptyModelID: return "LLM model ID must not be empty"
            case .nonHTTPResponse: return "LLM endpoint returned a non-HTTP response"
            case .httpStatus(let status): return "LLM endpoint returned HTTP status \(status)"
            case .responseTooLarge: return "LLM response exceeded the size limit"
            case .invalidResponse: return "LLM response did not match the required JSON schema"
            case .transport: return "LLM request failed"
            }
        }
    }

    private struct ResponseFormat: Encodable, Sendable {
        let type = "json_schema"
        let jsonSchema: Schema
        enum CodingKeys: String, CodingKey { case type; case jsonSchema = "json_schema" }
    }

    private struct Schema: Encodable, Sendable {
        let name = "event_enrichment"
        let strict = true
        let schema: [String: AnyEncodable]
    }

    private struct RequestBody: Encodable, Sendable {
        struct Message: Encodable, Sendable {
            let role: String
            let content: String
        }
        let model: String
        let messages: [Message]
        let responseFormat: ResponseFormat
        let temperature = 0
        enum CodingKeys: String, CodingKey {
            case model, messages, responseFormat = "response_format", temperature
        }
    }

    private struct DecodedEnrichment: Decodable {
        let sectors: [String]
        let stockCodes: [String]
        let impactScope: EventImpactScope?
        let priority: Int?
        enum CodingKeys: String, CodingKey {
            case sectors
            case stockCodes = "stockCodes"
            case impactScope = "impactScope"
            case priority
        }
    }

    private let endpoint: URL
    private let modelID: String
    private let transport: any EventLLMHTTPTransport
    private let maximumResponseBytes: Int

    public init(endpoint: URL, modelID: String,
                transport: any EventLLMHTTPTransport = URLSessionEventLLMHTTPTransport(),
                maximumResponseBytes: Int = 1_000_000) throws {
        guard endpoint.scheme?.lowercased() == "https", endpoint.host != nil,
              endpoint.query == nil, endpoint.fragment == nil,
              endpoint.user == nil, endpoint.password == nil else {
            throw Error.invalidEndpoint
        }
        guard !modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.emptyModelID
        }
        self.endpoint = endpoint
        self.modelID = modelID
        self.transport = transport
        self.maximumResponseBytes = max(1_024, maximumResponseBytes)
    }

    public func enrich(_ request: EventLLMEnrichmentRequest) async throws -> EventLLMEnrichment {
        try Task.checkCancellation()
        let body = RequestBody(
            model: modelID,
            messages: [
                .init(role: "system", content: "Extract event metadata. Return only JSON matching the supplied schema."),
                .init(role: "user", content: userContent(for: request.event))
            ],
            responseFormat: ResponseFormat(jsonSchema: Schema(schema: Self.schemaProperties)))
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(body)
        } catch {
            throw Error.invalidResponse
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = 30
        urlRequest.httpBody = bodyData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        // The key exists only in this transient request header and is never included in a URL.
        urlRequest.setValue("Bearer \(request.apiKey)", forHTTPHeaderField: "Authorization")

        let response: EventHTTPResponse
        do {
            response = try await transport.send(urlRequest)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Error {
            throw error
        } catch {
            throw Error.transport
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode) else { throw Error.httpStatus(response.statusCode) }
        guard response.data.count <= maximumResponseBytes else { throw Error.responseTooLarge }
        return try parse(response.data)
    }

    private func userContent(for event: MarketEvent) -> String {
        var values: [String: Any] = ["sourceID": event.sourceID, "title": event.title]
        if let body = event.body { values["body"] = body }
        if !event.sectors.isEmpty { values["existingSectors"] = event.sectors }
        if !event.stockCodes.isEmpty { values["existingStockCodes"] = event.stockCodes }
        return (try? JSONSerialization.data(withJSONObject: values))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func parse(_ data: Data) throws -> EventLLMEnrichment {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = object["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any],
              let content = message["content"] as? String,
              let contentData = content.data(using: .utf8),
              let contentObject = try? JSONSerialization.jsonObject(with: contentData) as? [String: Any],
              contentObject.keys.contains("sectors"), contentObject.keys.contains("stockCodes"),
              contentObject.keys.contains("impactScope"), contentObject.keys.contains("priority") else {
            throw Error.invalidResponse
        }
        do {
            let decoded = try JSONDecoder().decode(DecodedEnrichment.self, from: contentData)
            guard decoded.sectors.count <= 8, decoded.stockCodes.count <= 20 else { throw Error.invalidResponse }
            guard decoded.sectors.allSatisfy({ let value = $0.trimmingCharacters(in: .whitespacesAndNewlines); return !value.isEmpty && value.count <= 64 }),
                  decoded.stockCodes.allSatisfy({ $0.range(of: "^[0-9]{6}$", options: .regularExpression) != nil }) else {
                throw Error.invalidResponse
            }
            if let priority = decoded.priority, !(1...5).contains(priority) { throw Error.invalidResponse }
            let usage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["usage"] as? [String: Any]
            return EventLLMEnrichment(sectors: decoded.sectors, stockCodes: decoded.stockCodes,
                impactScope: decoded.impactScope, priority: decoded.priority,
                promptTokenCount: Self.usageCount(usage?["prompt_tokens"]),
                completionTokenCount: Self.usageCount(usage?["completion_tokens"]),
                totalTokenCount: Self.usageCount(usage?["total_tokens"]))
        } catch let error as Error {
            throw error
        } catch {
            throw Error.invalidResponse
        }
    }

    private static func usageCount(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double <= Double(Int.max), double.rounded() == double else { return nil }
        return Int(double)
    }

    private static let schemaProperties: [String: AnyEncodable] = [
        "type": AnyEncodable("object"),
        "additionalProperties": AnyEncodable(false),
        "properties": AnyEncodable([
            "sectors": ["type": "array", "maxItems": 8, "items": ["type": "string", "maxLength": 64]],
            "stockCodes": ["type": "array", "maxItems": 20, "items": ["type": "string", "pattern": "^[0-9]{6}$"]],
            "impactScope": ["type": ["string", "null"], "enum": ["market", "sector", "stock", "unknown", NSNull()]],
            "priority": ["type": ["integer", "null"], "minimum": 1, "maximum": 5]
        ]),
        "required": AnyEncodable(["sectors", "stockCodes", "impactScope", "priority"])
    ]
}

private struct AnyEncodable: Encodable, @unchecked Sendable {
    private let encodeValue: (Encoder) throws -> Void
    init(_ value: Any) { encodeValue = { encoder in try AnyEncodable.encode(value, into: encoder) } }
    func encode(to encoder: Encoder) throws { try encodeValue(encoder) }
    private static func encode(_ value: Any, into encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case let value as String: try container.encode(value)
        case let value as Int: try container.encode(value)
        case let value as Bool: try container.encode(value)
        case is NSNull: try container.encodeNil()
        case let value as [String]: try container.encode(value)
        case let value as [Any]: try container.encode(value.map(AnyEncodable.init))
        case let value as [String: Any]: try container.encode(value.mapValues(AnyEncodable.init))
        default: throw EncodingError.invalidValue(value, .init(codingPath: encoder.codingPath, debugDescription: "Unsupported JSON value"))
        }
    }
}

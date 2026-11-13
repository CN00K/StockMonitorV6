import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct AnalystStockFacts: Codable, Sendable, Equatable {
    public let code: String
    public let name: String
    public let currentPrice: Double
    public let previousClose: Double?
    public let open: Double?
    public let high: Double?
    public let low: Double?
    public let volume: Int64?
    public let amount: Double?
    public let quoteTimestamp: Date?
    public let quoteSourceID: String?
    public let quoteTimestampIsProvider: Bool

    public init(code: String, name: String, currentPrice: Double, previousClose: Double? = nil,
                open: Double? = nil, high: Double? = nil, low: Double? = nil,
                volume: Int64? = nil, amount: Double? = nil, quoteTimestamp: Date? = nil,
                quoteSourceID: String? = nil, quoteTimestampIsProvider: Bool = false) {
        self.code = code; self.name = name; self.currentPrice = currentPrice
        self.previousClose = previousClose; self.open = open; self.high = high; self.low = low
        self.volume = volume; self.amount = amount; self.quoteTimestamp = quoteTimestamp
        self.quoteSourceID = quoteSourceID; self.quoteTimestampIsProvider = quoteTimestampIsProvider
    }
}

public struct AnalystPricePoint: Codable, Sendable, Equatable {
    public let timestamp: Date
    public let open: Double?
    public let high: Double?
    public let low: Double?
    public let close: Double
    public let volume: Int64?

    public init(timestamp: Date, open: Double? = nil, high: Double? = nil, low: Double? = nil,
                close: Double, volume: Int64? = nil) {
        self.timestamp = timestamp; self.open = open; self.high = high; self.low = low
        self.close = close; self.volume = volume
    }
}

public struct AnalystEvent: Codable, Sendable, Equatable {
    public let timestamp: Date?
    public let title: String
    public let detail: String?
    public let source: String?

    public init(timestamp: Date? = nil, title: String, detail: String? = nil, source: String? = nil) {
        self.timestamp = timestamp; self.title = title; self.detail = detail; self.source = source
    }
}

public struct AnalystContext: Codable, Sendable, Equatable {
    public let stock: AnalystStockFacts
    public let history: [AnalystPricePoint]
    public let events: [AnalystEvent]

    public init(stock: AnalystStockFacts, history: [AnalystPricePoint] = [], events: [AnalystEvent] = []) {
        self.stock = stock; self.history = history; self.events = events
    }
}

public struct OnDemandAnalystConfiguration: Sendable, Equatable {
    public let endpoint: URL
    public let modelID: String
    public let timeout: TimeInterval

    public init(endpoint: URL, modelID: String, timeout: TimeInterval = 60) {
        self.endpoint = endpoint; self.modelID = modelID; self.timeout = timeout
    }
}

public protocol AnalystTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

private final class AnalystNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct URLSessionAnalystTransport: AnalystTransport {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: AnalystNoRedirectDelegate(), delegateQueue: nil)
    }()

    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await Self.session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OnDemandAnalystError.invalidResponse }
        return (data, http)
    }
}

public enum OnDemandAnalystError: Error, Equatable, Sendable {
    case invalidConfiguration
    case invalidContext
    case invalidAPIKey
    case network
    case httpStatus(Int)
    case invalidResponse
    case validationFailed
}

public struct AnalystSupervisorResponse: Codable, Sendable, Equatable {
    public let signal: String
    public let confidence: Double
    public let summary: String
    public let risk: String
}

public struct AnalystSpecialistResponse: Codable, Sendable, Equatable {
    public let score: Double
    public let narrative: String
}

public struct OnDemandAnalyst: Sendable {
    private let transport: any AnalystTransport

    public init(transport: any AnalystTransport = URLSessionAnalystTransport()) {
        self.transport = transport
    }

    public func analyze(context: AnalystContext, configuration: OnDemandAnalystConfiguration,
                       apiKey: String) async throws -> StrategyResult {
        guard configuration.endpoint.scheme?.lowercased() == "https",
              configuration.endpoint.host != nil,
              configuration.endpoint.user == nil, configuration.endpoint.password == nil,
              configuration.endpoint.query == nil, configuration.endpoint.fragment == nil,
              !configuration.modelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OnDemandAnalystError.invalidConfiguration
        }
        guard context.stock.code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil,
              !context.stock.name.isEmpty, context.stock.name.count <= 120,
              context.stock.currentPrice.isFinite, context.stock.currentPrice > 0,
              [context.stock.previousClose, context.stock.open, context.stock.high, context.stock.low,
               context.stock.amount].compactMap({ $0 }).allSatisfy(\.isFinite),
              context.stock.volume.map({ $0 >= 0 }) ?? true,
              context.stock.quoteSourceID.map({ $0.count <= 128 }) ?? true,
              context.history.count <= 60, context.events.count <= 20,
              context.history.allSatisfy({ point in
                  [point.open, point.high, point.low].compactMap({ $0 }).allSatisfy(\.isFinite) &&
                  point.close.isFinite && point.close > 0 && (point.volume.map { $0 >= 0 } ?? true)
              }),
              zip(context.history, context.history.dropFirst()).allSatisfy({ pair in pair.0.timestamp <= pair.1.timestamp }),
              context.events.allSatisfy({ !$0.title.isEmpty && $0.title.count <= 500 &&
                  ($0.detail?.count ?? 0) <= 2_000 && ($0.source?.count ?? 0) <= 128 }) else {
            throw OnDemandAnalystError.invalidContext
        }
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw OnDemandAnalystError.invalidAPIKey }

        async let supervisor = requestSupervisor(context: context, configuration: configuration, apiKey: apiKey)
        async let technical = requestSpecialist(kind: "technical", context: context, configuration: configuration, apiKey: apiKey)
        async let fundamental = requestSpecialist(kind: "fundamental", context: context, configuration: configuration, apiKey: apiKey)
        async let sentiment = requestSpecialist(kind: "sentiment", context: context, configuration: configuration, apiKey: apiKey)
        async let risk = requestSpecialist(kind: "risk", context: context, configuration: configuration, apiKey: apiKey)
        let (lead, tech, fund, sent, riskResult) = try await (supervisor, technical, fundamental, sentiment, risk)
        try Task.checkCancellation()
        return try await requestRefinement(context: context, supervisor: lead, technical: tech,
                                           fundamental: fund, sentiment: sent, risk: riskResult,
                                           configuration: configuration, apiKey: apiKey)
    }

    private func requestSupervisor(context: AnalystContext, configuration: OnDemandAnalystConfiguration,
                                   apiKey: String) async throws -> AnalystSupervisorResponse {
        let instruction = "Act as supervisor. Use only supplied facts, history, and events; never invent facts. Label missing fields as missing. Include risk in summary. This is not investment advice. Return only the requested JSON object."
        let contextJSON = try encodedContext(context)
        return try await send(schema: Self.supervisorSchema, system: instruction, user: contextJSON,
                              configuration: configuration, apiKey: apiKey)
    }

    private func requestSpecialist(kind: String, context: AnalystContext, configuration: OnDemandAnalystConfiguration,
                                   apiKey: String) async throws -> AnalystSpecialistResponse {
        let instruction = "Act as the \(kind) specialist. Use only supplied facts, history, and events; never invent facts. Label missing fields as missing. Include relevant risks and say when evidence is insufficient. This is not investment advice. Return only the requested JSON object."
        let contextJSON = try encodedContext(context)
        return try await send(schema: Self.specialistSchema, system: instruction, user: contextJSON,
                              configuration: configuration, apiKey: apiKey)
    }

    private func requestRefinement(context: AnalystContext, supervisor: AnalystSupervisorResponse,
                                   technical: AnalystSpecialistResponse, fundamental: AnalystSpecialistResponse,
                                   sentiment: AnalystSpecialistResponse, risk: AnalystSpecialistResponse,
                                   configuration: OnDemandAnalystConfiguration, apiKey: String) async throws -> StrategyResult {
        let contextJSON = try encodedContext(context)
        let supervisorJSON = try encoded(supervisor)
        let technicalJSON = try encoded(technical)
        let fundamentalJSON = try encoded(fundamental)
        let sentimentJSON = try encoded(sentiment)
        let riskJSON = try encoded(risk)
        let payload = "context=\(contextJSON); supervisor=\(supervisorJSON); technical=\(technicalJSON); fundamental=\(fundamentalJSON); sentiment=\(sentimentJSON); risk=\(riskJSON)"
        let instruction = "Refine the supplied analyses into the exact StrategyResult contract. Never invent facts; label missing fields. Include risk in summary. This is not investment advice. Return only JSON with exactly the schema keys."
        return try await send(schema: Self.resultSchema, system: instruction, user: payload,
                              configuration: configuration, apiKey: apiKey)
    }

    private func send<T: Decodable>(schema: [String: Any], system: String, user: String,
                                    configuration: OnDemandAnalystConfiguration, apiKey: String) async throws -> T {
        try Task.checkCancellation()
        let body: [String: Any] = ["model": configuration.modelID, "messages": [["role": "system", "content": system], ["role": "user", "content": user]], "response_format": ["type": "json_schema", "json_schema": ["name": "analysis", "strict": true, "schema": schema]]]
        let data = try JSONSerialization.data(withJSONObject: body)
        var request = URLRequest(url: configuration.endpoint, timeoutInterval: configuration.timeout)
        request.httpMethod = "POST"; request.httpBody = data
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let response: (Data, HTTPURLResponse)
        do { response = try await transport.send(request) } catch { throw OnDemandAnalystError.network }
        guard (200...299).contains(response.1.statusCode) else { throw OnDemandAnalystError.httpStatus(response.1.statusCode) }
        guard response.0.count <= 1_000_000 else { throw OnDemandAnalystError.invalidResponse }
        guard let content = try? Self.extractContent(response.0) else { throw OnDemandAnalystError.invalidResponse }
        do { return try Self.decodeAndValidate(T.self, data: content) } catch { throw OnDemandAnalystError.validationFailed }
    }

    private func encodedContext(_ context: AnalystContext) throws -> String { try encoded(context) }
    private func encoded<T: Encodable>(_ value: T) throws -> String {
        let data: Data
        do { data = try JSONEncoder().encode(value) }
        catch { throw OnDemandAnalystError.invalidContext }
        guard let text = String(data: data, encoding: .utf8) else { throw OnDemandAnalystError.invalidContext }
        return text
    }

    private static func extractContent(_ data: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let choices = object?["choices"] as? [[String: Any]], let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String, let contentData = content.data(using: .utf8) else { throw OnDemandAnalystError.invalidResponse }
        return contentData
    }

    private static func decodeAndValidate<T: Decodable>(_ type: T.Type, data: Data) throws -> T {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else { throw OnDemandAnalystError.validationFailed }
        let allowed: Set<String>
        if type == AnalystSupervisorResponse.self { allowed = ["signal", "confidence", "summary", "risk"] }
        else if type == AnalystSpecialistResponse.self { allowed = ["score", "narrative"] }
        else { allowed = ["signal", "confidence", "target_price", "stop_loss_price", "scores", "summary", "technical", "fundamental", "sentiment"] }
        guard Set(dictionary.keys) == allowed else { throw OnDemandAnalystError.validationFailed }
        if type == StrategyResult.self {
            guard let scores = dictionary["scores"] as? [String: Any],
                  Set(scores.keys) == ["technical", "fundamental", "sentiment", "risk"] else {
                throw OnDemandAnalystError.validationFailed
            }
        }
        let result = try JSONDecoder().decode(type, from: data)
        if let value = result as? AnalystSupervisorResponse {
            guard ["买入", "卖出", "持有", "观望"].contains(value.signal), value.confidence.isFinite, (0...1).contains(value.confidence), !value.summary.isEmpty, value.summary.count <= 4_000, !value.risk.isEmpty, value.risk.count <= 4_000 else { throw OnDemandAnalystError.validationFailed }
        } else if let value = result as? AnalystSpecialistResponse {
            guard value.score.isFinite, (0...100).contains(value.score), !value.narrative.isEmpty, value.narrative.count <= 4000 else { throw OnDemandAnalystError.validationFailed }
        } else if let value = result as? StrategyResult {
            let scores = value.scores
            guard ["买入", "卖出", "持有", "观望"].contains(value.signal), value.confidence.isFinite, (0...1).contains(value.confidence), [scores.technical, scores.fundamental, scores.sentiment, scores.risk].allSatisfy({ $0.isFinite && (0...100).contains($0) }), [value.summary, value.technical, value.fundamental, value.sentiment].allSatisfy({ !$0.isEmpty && $0.count <= 4000 }), [value.targetPrice, value.stopLossPrice].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 > 0 }) else { throw OnDemandAnalystError.validationFailed }
        }
        return result
    }

    private static let supervisorSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "properties": [
            "signal": ["type": "string", "enum": ["买入", "卖出", "持有", "观望"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "summary": ["type": "string", "minLength": 1, "maxLength": 4000],
            "risk": ["type": "string", "minLength": 1, "maxLength": 4000]
        ],
        "required": ["signal", "confidence", "summary", "risk"]
    ]
    private static let specialistSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "properties": [
            "score": ["type": "number", "minimum": 0, "maximum": 100],
            "narrative": ["type": "string", "minLength": 1, "maxLength": 4000]
        ],
        "required": ["score", "narrative"]
    ]
    private static let resultSchema: [String: Any] = [
        "type": "object", "additionalProperties": false,
        "properties": [
            "signal": ["type": "string", "enum": ["买入", "卖出", "持有", "观望"]],
            "confidence": ["type": "number", "minimum": 0, "maximum": 1],
            "target_price": ["type": ["number", "null"], "minimum": 0],
            "stop_loss_price": ["type": ["number", "null"], "minimum": 0],
            "scores": ["type": "object", "additionalProperties": false, "properties": [
                "technical": ["type": "number", "minimum": 0, "maximum": 100],
                "fundamental": ["type": "number", "minimum": 0, "maximum": 100],
                "sentiment": ["type": "number", "minimum": 0, "maximum": 100],
                "risk": ["type": "number", "minimum": 0, "maximum": 100]
            ], "required": ["technical", "fundamental", "sentiment", "risk"]],
            "summary": ["type": "string", "minLength": 1, "maxLength": 4000],
            "technical": ["type": "string", "minLength": 1, "maxLength": 4000],
            "fundamental": ["type": "string", "minLength": 1, "maxLength": 4000],
            "sentiment": ["type": "string", "minLength": 1, "maxLength": 4000]
        ],
        "required": ["signal", "confidence", "target_price", "stop_loss_price", "scores", "summary", "technical", "fundamental", "sentiment"]
    ]
}

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A nullable snapshot of the fields actually observed in Eastmoney's public
/// unofficial stock/get response. This is community-only data, not an official
/// contract; fields absent from the response remain nil.
public struct EastmoneyFundamentalSnapshot: Codable, Sendable, Equatable {
    public let code: String?
    public let name: String?
    public let peDynamic: Double?
    public let pb: Double?
    public let totalMarketValue: Double?
    public let floatMarketValue: Double?
    public let roe: Double?
    public let grossMargin: Double?
    public let netMargin: Double?
    public let netProfit: Double?
    public let industry: String?
    public let unavailableFields: [String]
    public let sourceID: String
    public let fetchedAt: Date

    public init(code: String? = nil, name: String? = nil, peDynamic: Double? = nil,
                pb: Double? = nil, totalMarketValue: Double? = nil,
                floatMarketValue: Double? = nil, roe: Double? = nil,
                grossMargin: Double? = nil, netMargin: Double? = nil,
                netProfit: Double? = nil, industry: String? = nil,
                unavailableFields: [String] = [], sourceID: String = "eastmoney-fundamentals",
                fetchedAt: Date = Date()) {
        self.code = code; self.name = name; self.peDynamic = peDynamic; self.pb = pb
        self.totalMarketValue = totalMarketValue; self.floatMarketValue = floatMarketValue
        self.roe = roe; self.grossMargin = grossMargin; self.netMargin = netMargin
        self.netProfit = netProfit; self.industry = industry
        self.unavailableFields = unavailableFields; self.sourceID = sourceID; self.fetchedAt = fetchedAt
    }

    /// Only semantically equivalent fields map into FactorObservation.
    /// Eastmoney's dynamic PE is not PE-TTM, so peTTM remains unknown.
    public var factorObservation: FactorObservation {
        FactorObservation(pb: pb, totalMarketValue: totalMarketValue,
                          roe: roe, grossProfitMargin: grossMargin)
    }
}

public enum EastmoneyFundamentalsError: Error, LocalizedError, Equatable {
    case unsupportedCode(String)
    case invalidURL
    case httpStatus(Int)
    case nonJSONResponse
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .unsupportedCode(let code): return "Unsupported or invalid six-digit stock code: \(code)"
        case .invalidURL: return "Unable to construct Eastmoney fundamentals URL"
        case .httpStatus(let status): return "Eastmoney fundamentals HTTP status \(status)"
        case .nonJSONResponse: return "Eastmoney fundamentals returned HTML or a challenge page, not JSON"
        case .malformedResponse: return "Malformed Eastmoney fundamentals JSON response"
        }
    }
}

/// Eastmoney's public, undocumented /api/qt/stock/get endpoint.
public struct EastmoneyFundamentalsSource: @unchecked Sendable {
    public let identifier = "eastmoney-fundamentals"
    private let session: URLSession
    private let budget: RequestBudget

    public init(session: URLSession = .shared, budget: RequestBudget = .standard()) {
        self.session = session
        self.budget = budget
    }

    public func fetch(code: String) async throws -> EastmoneyFundamentalSnapshot {
        let secid = try Self.securityID(for: code)
        try await budget.acquire(host: "push2.eastmoney.com")
        var components = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/get")
        components?.queryItems = [
            URLQueryItem(name: "secid", value: secid),
            URLQueryItem(name: "fields", value: "f57,f58,f105,f116,f117,f127,f162,f167,f173,f186,f187")
        ]
        guard let url = components?.url else { throw EastmoneyFundamentalsError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        request.setValue("https://quote.eastmoney.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw EastmoneyFundamentalsError.httpStatus((response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        return try Self.parse(data: data, fetchedAt: Date())
    }

    public func fetchFundamentals(code: String) async throws -> EastmoneyFundamentalSnapshot {
        try await fetch(code: code)
    }

    /// Maps Shanghai 6/9 codes to market 1 and Shenzhen/BJ 0 codes to market 0.
    public static func securityID(for code: String) throws -> String {
        guard code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else {
            throw EastmoneyFundamentalsError.unsupportedCode(code)
        }
        let prefix = code.first!
        guard "69".contains(prefix) || "0348".contains(prefix) else {
            throw EastmoneyFundamentalsError.unsupportedCode(code)
        }
        let market = "69".contains(prefix) ? 1 : 0
        return "\(market).\(code)"
    }

    public static func parse(data: Data, fetchedAt: Date = Date()) throws -> EastmoneyFundamentalSnapshot {
        let leadingWhitespace = Data(data.prefix { byte in byte == 9 || byte == 10 || byte == 13 || byte == 32 })
        let trimmed = data.dropFirst(leadingWhitespace.count)
        guard !trimmed.isEmpty, trimmed.first != 60 else {
            throw EastmoneyFundamentalsError.nonJSONResponse
        }
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
        catch { throw EastmoneyFundamentalsError.nonJSONResponse }
        guard let root = object as? [String: Any], let payload = root["data"] as? [String: Any] else {
            throw EastmoneyFundamentalsError.malformedResponse
        }
        return parse(payload: payload, fetchedAt: fetchedAt)
    }

    public static func parse(jsonData: Data, fetchedAt: Date = Date()) throws -> EastmoneyFundamentalSnapshot {
        try parse(data: jsonData, fetchedAt: fetchedAt)
    }

    public static func parse(payload: [String: Any], fetchedAt: Date = Date()) -> EastmoneyFundamentalSnapshot {
        let fields = ["peDynamic", "pb", "totalMarketValue", "floatMarketValue", "roe", "grossMargin", "netMargin", "netProfit", "industry"]
        let values: [(String, Double?)] = [
            ("peDynamic", normalizedVal(payload["f162"], divisor: 100)),
            ("pb", normalizedVal(payload["f167"], divisor: 100)),
            ("totalMarketValue", finiteNumber(payload["f116"])),
            ("floatMarketValue", finiteNumber(payload["f117"])),
            ("roe", finiteNumber(payload["f173"])),
            ("grossMargin", finiteNumber(payload["f186"])),
            ("netMargin", finiteNumber(payload["f187"])),
            ("netProfit", finiteNumber(payload["f105"]))
        ]
        let unavailable = fields.filter { key in
            switch key {
            case "industry": return string(payload["f127"]) == nil
            default: return values.first { $0.0 == key }?.1 == nil
            }
        }
        return EastmoneyFundamentalSnapshot(code: string(payload["f57"]), name: string(payload["f58"]),
            peDynamic: values[0].1, pb: values[1].1, totalMarketValue: values[2].1,
            floatMarketValue: values[3].1, roe: values[4].1, grossMargin: values[5].1,
            netMargin: values[6].1, netProfit: values[7].1, industry: string(payload["f127"]),
            unavailableFields: unavailable, fetchedAt: fetchedAt)
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func normalizedVal(_ value: Any?, divisor: Double) -> Double? {
        finiteNumber(value).map { $0 / divisor }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String, !value.isEmpty { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
}

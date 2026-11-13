import Foundation

public enum QuoteKind: String, Codable, Sendable {
    case stock, index
}

public struct Quote: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }
    public let code: String
    public let name: String
    public let timestamp: Date
    public let price: Double
    public let previousClose: Double
    public let open: Double
    public let high: Double
    public let low: Double
    public let volume: Int64
    public let amount: Double?
    public let sourceID: String
    public let retrievedAt: Date
    public let timestampIsProvider: Bool
    public let kind: QuoteKind

    public var change: Double { price - previousClose }
    public var changePercent: Double {
        guard previousClose > 0 else { return 0 }
        return change / previousClose * 100
    }

    public init(code: String, name: String, timestamp: Date, price: Double,
                previousClose: Double, open: Double, high: Double, low: Double,
                volume: Int64, amount: Double? = nil, sourceID: String = "manual",
                retrievedAt: Date = Date(), timestampIsProvider: Bool = true,
                kind: QuoteKind = .stock) {
        self.code = code
        self.name = name
        self.timestamp = timestamp
        self.price = price
        self.previousClose = previousClose
        self.open = open
        self.high = high
        self.low = low
        self.volume = volume
        self.amount = amount
        self.sourceID = sourceID
        self.retrievedAt = retrievedAt
        self.timestampIsProvider = timestampIsProvider
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case code, name, timestamp, price, previousClose, open, high, low, volume, amount
        case sourceID, retrievedAt, timestampIsProvider, kind
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = try values.decode(String.self, forKey: .code)
        name = try values.decode(String.self, forKey: .name)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        price = try values.decode(Double.self, forKey: .price)
        previousClose = try values.decode(Double.self, forKey: .previousClose)
        open = try values.decode(Double.self, forKey: .open)
        high = try values.decode(Double.self, forKey: .high)
        low = try values.decode(Double.self, forKey: .low)
        volume = try values.decode(Int64.self, forKey: .volume)
        amount = try values.decodeIfPresent(Double.self, forKey: .amount)
        sourceID = try values.decodeIfPresent(String.self, forKey: .sourceID) ?? "unknown"
        retrievedAt = try values.decodeIfPresent(Date.self, forKey: .retrievedAt) ?? timestamp
        timestampIsProvider = try values.decodeIfPresent(Bool.self, forKey: .timestampIsProvider) ?? true
        kind = try values.decodeIfPresent(QuoteKind.self, forKey: .kind) ?? .stock
    }
}

public struct LimitPair: Codable, Sendable, Equatable {
    public let up: Double
    public let down: Double

    public init(up: Double, down: Double) {
        self.up = up
        self.down = down
    }
}

public struct MarketSnapshot: Codable, Sendable, Equatable {
    public let capturedAt: Date
    public let quotes: [Quote]
    public let indexQuotes: [Quote]
    public let limits: [String: LimitPair]
    public let sourceStatuses: [SourceStatus]
    public let limitPriceStatus: String

    public init(capturedAt: Date = Date(), quotes: [Quote], indexQuotes: [Quote] = [],
                limits: [String: LimitPair] = [:], sourceStatuses: [SourceStatus] = [],
                limitPriceStatus: String = "Daily limit-price source unavailable") {
        self.capturedAt = capturedAt
        self.quotes = quotes
        self.indexQuotes = indexQuotes
        self.limits = limits
        self.sourceStatuses = sourceStatuses
        self.limitPriceStatus = limitPriceStatus
    }
}

public struct Holding: Codable, Sendable, Equatable, Identifiable {
    public var id: String { code }
    public let code: String
    public let shares: Int64
    public let averageCost: Double
    public let updatedAt: Date

    public init(code: String, shares: Int64, averageCost: Double, updatedAt: Date = Date()) {
        self.code = code
        self.shares = max(0, shares)
        self.averageCost = max(0, averageCost)
        self.updatedAt = updatedAt
    }
}

public enum AlertLevel: Int, Codable, Sendable, Comparable {
    case info = 0
    case warning = 1
    case urgent = 2

    public static func < (lhs: AlertLevel, rhs: AlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AlertSignal: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public let code: String
    public let ruleID: String
    public let level: AlertLevel
    public let title: String
    public let detail: String
    public let createdAt: Date

    public init(id: UUID = UUID(), code: String, ruleID: String, level: AlertLevel,
                title: String, detail: String, createdAt: Date = Date()) {
        self.id = id
        self.code = code
        self.ruleID = ruleID
        self.level = level
        self.title = title
        self.detail = detail
        self.createdAt = createdAt
    }
}

/// Contract for a future on-device/remote LLM analysis response. No model provider
/// or credentials are bundled in this initial scaffold.
public struct StrategyResult: Codable, Sendable, Equatable {
    public let signal: String
    public let confidence: Double
    public let targetPrice: Double?
    public let stopLossPrice: Double?
    public let scores: Scores
    public let summary: String
    public let technical: String
    public let fundamental: String
    public let sentiment: String

    public struct Scores: Codable, Sendable, Equatable {
        public let technical: Double
        public let fundamental: Double
        public let sentiment: Double
        public let risk: Double
    }

    enum CodingKeys: String, CodingKey {
        case signal, confidence
        case targetPrice = "target_price"
        case stopLossPrice = "stop_loss_price"
        case scores, summary, technical, fundamental, sentiment
    }
}

import Foundation

public enum RuleCondition: Sendable, Equatable, Codable {
    case changePercentAtLeast(Double)
    case changePercentAtMost(Double)
    case priceAtLeast(Double)
    case priceAtMost(Double)
    case volumeAtLeast(Int64)
    case limitUp(tolerance: Double)
    case limitDown(tolerance: Double)

    private enum CodingKeys: String, CodingKey { case kind, value }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try values.decode(String.self, forKey: .kind)
        switch kind {
        case "changePercentAtLeast": self = .changePercentAtLeast(try values.decode(Double.self, forKey: .value))
        case "changePercentAtMost": self = .changePercentAtMost(try values.decode(Double.self, forKey: .value))
        case "priceAtLeast": self = .priceAtLeast(try values.decode(Double.self, forKey: .value))
        case "priceAtMost": self = .priceAtMost(try values.decode(Double.self, forKey: .value))
        case "volumeAtLeast": self = .volumeAtLeast(try values.decode(Int64.self, forKey: .value))
        case "limitUp": self = .limitUp(tolerance: try values.decode(Double.self, forKey: .value))
        case "limitDown": self = .limitDown(tolerance: try values.decode(Double.self, forKey: .value))
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: values,
                debugDescription: "Unknown rule condition: \(kind)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .changePercentAtLeast(let value):
            try values.encode("changePercentAtLeast", forKey: .kind); try values.encode(value, forKey: .value)
        case .changePercentAtMost(let value):
            try values.encode("changePercentAtMost", forKey: .kind); try values.encode(value, forKey: .value)
        case .priceAtLeast(let value):
            try values.encode("priceAtLeast", forKey: .kind); try values.encode(value, forKey: .value)
        case .priceAtMost(let value):
            try values.encode("priceAtMost", forKey: .kind); try values.encode(value, forKey: .value)
        case .volumeAtLeast(let value):
            try values.encode("volumeAtLeast", forKey: .kind); try values.encode(value, forKey: .value)
        case .limitUp(let tolerance):
            try values.encode("limitUp", forKey: .kind); try values.encode(tolerance, forKey: .value)
        case .limitDown(let tolerance):
            try values.encode("limitDown", forKey: .kind); try values.encode(tolerance, forKey: .value)
        }
    }
}

public struct WatchRule: Sendable, Equatable, Identifiable, Codable {
    public let id: String
    public let code: String
    public let title: String
    public let detail: String
    public let level: AlertLevel
    public let condition: RuleCondition
    public let sustainedTicks: Int
    public let cooldown: TimeInterval

    public init(id: String, code: String, title: String, detail: String,
                level: AlertLevel = .warning, condition: RuleCondition,
                sustainedTicks: Int = 1, cooldown: TimeInterval = 300) {
        self.id = id
        self.code = code
        self.title = title
        self.detail = detail
        self.level = level
        self.condition = condition
        self.sustainedTicks = max(1, sustainedTicks)
        self.cooldown = max(0, cooldown)
    }
}

public struct RuleEngine: Sendable {
    private var rules: [WatchRule]
    private var streaks: [String: Int] = [:]
    private var lastFiredAt: [String: Date] = [:]

    public init(rules: [WatchRule] = []) { self.rules = rules }

    public mutating func replaceRules(_ rules: [WatchRule]) {
        self.rules = rules
        streaks.removeAll()
        lastFiredAt.removeAll()
    }

    /// New evaluator instance keeps replay streak/cooldown state separate from live monitoring.
    public func historicalEvaluator() -> RuleEngine {
        RuleEngine(rules: rules.filter {
            if case .limitUp = $0.condition { return false }
            if case .limitDown = $0.condition { return false }
            return true
        })
    }

    /// Percent rules are evaluated only for bars with a known prior close. Historical
    /// limit rules stay disabled; live rules may use the snapshot's explicitly labeled
    /// local formula estimate, which is not an exchange-authoritative limit price.
    public mutating func evaluateHistorical(current: MarketSnapshot,
                                             previousCloseKnownCodes: Set<String>,
                                             now: Date) -> [AlertSignal] {
        let originalRules = rules
        rules = originalRules.filter { rule in
            switch rule.condition {
            case .changePercentAtLeast, .changePercentAtMost:
                return previousCloseKnownCodes.contains(rule.code)
            case .limitUp, .limitDown:
                return false
            default:
                return true
            }
        }
        let signals = evaluate(current: current, now: now)
        rules = originalRules
        return signals
    }

    public mutating func evaluate(current: MarketSnapshot, previous: MarketSnapshot? = nil,
                                  now: Date = Date()) -> [AlertSignal] {
        _ = previous // Reserved for crossing/transition rules in the full rule set.
        var quotes: [String: Quote] = [:]
        for quote in current.quotes where quote.kind == .stock { quotes[quote.code] = quote }
        var fired: [AlertSignal] = []
        for rule in rules {
            guard let quote = quotes[rule.code] else { continue }
            let matched = matches(rule.condition, quote: quote, limits: current.limits[quote.code])
            let key = rule.id + ":" + quote.code
            streaks[key] = matched ? (streaks[key, default: 0] + 1) : 0
            guard matched, streaks[key, default: 0] >= rule.sustainedTicks else { continue }
            if let last = lastFiredAt[key], now.timeIntervalSince(last) < rule.cooldown { continue }
            fired.append(AlertSignal(code: quote.code, ruleID: rule.id, level: rule.level,
                                     title: rule.title, detail: rule.detail, createdAt: now))
            lastFiredAt[key] = now
        }
        return fired
    }

    private func matches(_ condition: RuleCondition, quote: Quote, limits: LimitPair?) -> Bool {
        switch condition {
        case .changePercentAtLeast(let value): return quote.changePercent >= value
        case .changePercentAtMost(let value): return quote.changePercent <= value
        case .priceAtLeast(let value): return quote.price >= value
        case .priceAtMost(let value): return quote.price <= value
        case .volumeAtLeast(let value): return quote.volume >= value
        case .limitUp(let tolerance):
            guard let limits else { return false }
            return quote.price >= limits.up - max(0, tolerance)
        case .limitDown(let tolerance):
            guard let limits else { return false }
            return quote.price <= limits.down + max(0, tolerance)
        }
    }
}

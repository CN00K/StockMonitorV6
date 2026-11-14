import Foundation

public struct AnalystResultCacheKey: Sendable, Equatable {
    public let stockCode: String
    public let tradingDay: String
    public let endpointHost: String
    public let modelID: String
    public let contextFingerprint: String

    public init(stockCode: String, endpoint: URL, modelID: String, context: AnalystContext,
                at date: Date = Date(), maximumContextBytes: Int = 32_768) {
        self.stockCode = stockCode
        self.tradingDay = Self.chinaDayString(date)
        // URL.user, password, query, and fragment are deliberately ignored.
        let host = endpoint.host?.lowercased() ?? ""
        self.endpointHost = endpoint.port.map { "\(host):\($0)" } ?? host
        self.modelID = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.contextFingerprint = Self.contextFingerprint(context, maximumBytes: maximumContextBytes)
    }

    public var cacheID: String {
        [stockCode, tradingDay, endpointHost, modelID, contextFingerprint].joined(separator: "\u{1F}")
    }

    public static func contextFingerprint(_ context: AnalystContext, maximumBytes: Int = 32_768) -> String {
        let bounded = AnalystContext(
            stock: context.stock,
            history: Array(context.history.prefix(60)),
            events: Array(context.events.prefix(20)))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = (try? encoder.encode(bounded)) ?? Data()
        let limited = data.prefix(max(0, maximumBytes))
        // FNV-1a is deterministic, available on all supported platforms, and the
        // bounded input prevents untrusted context from becoming an unbounded key.
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in limited {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(format: "%016llx", hash)
    }

    private static func chinaDayString(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}

public struct AnalystUsageLedger: Sendable, Equatable {
    public let requestCount: Int
    public let promptTokenCount: Int?
    public let completionTokenCount: Int?
    public let totalTokenCount: Int?

    public init(requestCount: Int, promptTokenCount: Int? = nil, completionTokenCount: Int? = nil,
                totalTokenCount: Int? = nil) {
        self.requestCount = requestCount
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
        self.totalTokenCount = totalTokenCount
    }
}

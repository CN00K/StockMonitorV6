import Foundation

/// App navigation routes accepted by the stockmonitor URL scheme.
///
/// The parser deliberately accepts only the existing six tabs and a six-digit
/// A-share code. It performs no I/O and never normalizes malformed input into
/// a valid destination.
public enum StockMonitorTab: String, CaseIterable, Hashable, Sendable {
    case market
    case watchlist
    case monitor
    case feed
    case lab
    case settings

    public var displayName: String {
        switch self {
        case .market: "市场"
        case .watchlist: "自选"
        case .monitor: "监测"
        case .feed: "资讯"
        case .lab: "实验室"
        case .settings: "设置"
        }
    }
}

public enum StockMonitorRoute: Hashable, Sendable {
    case tab(StockMonitorTab)
    case stock(code: String)

    public static let urlScheme = "stockmonitor"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme,
              url.user == nil,
              url.password == nil,
              url.port == nil,
              url.query == nil,
              url.fragment == nil else { return nil }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = url.host, !host.isEmpty else { return nil }
        let encodedPath = components.percentEncodedPath
        guard encodedPath.hasPrefix("/"), !encodedPath.hasSuffix("/") else { return nil }
        let pathParts = encodedPath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard pathParts.count == 1,
              encodedPath == "/\(pathParts[0])",
              pathParts[0].removingPercentEncoding == pathParts[0] else { return nil }
        var parts: [String] = []
        parts.append(host)
        parts.append(contentsOf: pathParts)
        guard parts.count == 2,
              let kind = parts.first?.lowercased(),
              let value = parts.last,
              !value.isEmpty else { return nil }

        switch kind {
        case "tab":
            guard let tab = StockMonitorTab(rawValue: value.lowercased()) else { return nil }
            self = .tab(tab)
        case "stock":
            guard Self.isSafeStockCode(value) else { return nil }
            self = .stock(code: value)
        default:
            return nil
        }
    }

    public func destination(forWatchCodes watchCodes: [String]) -> StockMonitorRouteDestination? {
        switch self {
        case .tab(let tab):
            return .tab(tab)
        case .stock(let code):
            guard Self.isSafeStockCode(code) else { return nil }
            return watchCodes.contains(code)
                ? .monitoredStock(code: code)
                : .watchlistEntry(code: code)
        }
    }

    public static func isSafeStockCode(_ code: String) -> Bool {
        let bytes = Array(code.utf8)
        return bytes.count == 6 && bytes.allSatisfy { $0 >= 48 && $0 <= 57 }
    }
}

public enum StockMonitorRouteDestination: Equatable, Sendable {
    case tab(StockMonitorTab)
    case monitoredStock(code: String)
    case watchlistEntry(code: String)
}

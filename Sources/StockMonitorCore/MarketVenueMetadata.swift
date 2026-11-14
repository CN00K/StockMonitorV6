import Foundation

/// Supported listing venues. A venue is intentionally explicit for markets where a
/// ticker alone cannot safely distinguish an exchange or session.
public enum MarketVenue: String, Codable, Sendable, Equatable, CaseIterable {
    case aShare
    case hkex
    case nyse
    case nasdaq

    public var timeZoneIdentifier: String {
        switch self {
        case .aShare: return "Asia/Shanghai"
        case .hkex: return "Asia/Hong_Kong"
        case .nyse, .nasdaq: return "America/New_York"
        }
    }

    public var timeZone: TimeZone {
        TimeZone(identifier: timeZoneIdentifier)!
    }
}

public enum SecurityKind: String, Codable, Sendable, Equatable, CaseIterable {
    case stock
    case etf
}

public struct SessionWindow: Codable, Sendable, Equatable {
    public let startMinutes: Int
    public let endMinutes: Int

    public init(startMinutes: Int, endMinutes: Int) {
        precondition((0..<1440).contains(startMinutes) && (0...1440).contains(endMinutes))
        precondition(startMinutes < endMinutes)
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    public init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.init(startMinutes: startHour * 60 + startMinute, endMinutes: endHour * 60 + endMinute)
    }

    public func contains(hour: Int, minute: Int) -> Bool {
        (startMinutes..<endMinutes).contains(hour * 60 + minute)
    }
}

public struct MarketVenueMetadata: Codable, Sendable, Equatable {
    public let venue: MarketVenue
    public let securityKind: SecurityKind
    public let timeZoneIdentifier: String
    public let regularSessionWindows: [SessionWindow]

    public init(venue: MarketVenue, securityKind: SecurityKind) {
        self.venue = venue
        self.securityKind = securityKind
        self.timeZoneIdentifier = venue.timeZoneIdentifier
        switch venue {
        case .aShare:
            regularSessionWindows = [
                SessionWindow(startHour: 9, startMinute: 30, endHour: 11, endMinute: 30),
                SessionWindow(startHour: 13, startMinute: 0, endHour: 15, endMinute: 0)
            ]
        case .hkex:
            regularSessionWindows = [
                SessionWindow(startHour: 9, startMinute: 30, endHour: 12, endMinute: 0),
                SessionWindow(startHour: 13, startMinute: 0, endHour: 16, endMinute: 0)
            ]
        case .nyse, .nasdaq:
            regularSessionWindows = [SessionWindow(startHour: 9, startMinute: 30, endHour: 16, endMinute: 0)]
        }
    }

    public var timeZone: TimeZone { venue.timeZone }
}

public enum MarketSessionStatus: Sendable, Equatable {
    case open
    case closedWeekend
    case closedOutsideRegularSession
    /// A weekday/in-session instant for which this core has no verified holiday calendar.
    case unknownHoliday
}

public enum EastmoneySecIDPrefix: String, Codable, Sendable, Equatable {
    case shanghai = "1"
    case shenzhen = "0"
    case hkex = "116"
    case unitedStates = "105"

    /// Prefix 099 is intentionally not represented: it has not been verified here.
}

public struct EastmoneySecID: Codable, Sendable, Equatable {
    public let prefix: EastmoneySecIDPrefix
    public let symbol: String

    public init(prefix: EastmoneySecIDPrefix, symbol: String) {
        self.prefix = prefix
        self.symbol = symbol
    }

    public var value: String { "\(prefix.rawValue).\(symbol)" }
}

public struct MarketSymbolRoute: Codable, Sendable, Equatable {
    public let normalizedSymbol: String
    public let metadata: MarketVenueMetadata
    public let eastmoneySecID: EastmoneySecID?

    public init(normalizedSymbol: String, metadata: MarketVenueMetadata, eastmoneySecID: EastmoneySecID?) {
        self.normalizedSymbol = normalizedSymbol
        self.metadata = metadata
        self.eastmoneySecID = eastmoneySecID
    }
}

public enum MarketVenueCatalog {
    public static func metadata(for venue: MarketVenue, securityKind: SecurityKind = .stock) -> MarketVenueMetadata {
        MarketVenueMetadata(venue: venue, securityKind: securityKind)
    }

    /// Routes only the explicitly supported Eastmoney prefix families. A-share
    /// prefix selection is limited to established six-digit exchange code families;
    /// no fallback (including 099) is emitted for an unrecognized symbol.
    public static func route(symbol: String, venue: MarketVenue, securityKind: SecurityKind = .stock) -> MarketSymbolRoute? {
        let normalized = symbol.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else { return nil }
        let prefix: EastmoneySecIDPrefix?
        switch venue {
        case .aShare:
            guard normalized.range(of: "^[0-9]{6}$", options: .regularExpression) != nil else { return nil }
            prefix = aSharePrefix(for: normalized)
        case .hkex:
            guard normalized.range(of: "^[0-9]{1,5}$", options: .regularExpression) != nil else { return nil }
            prefix = .hkex
        case .nyse, .nasdaq:
            guard normalized.range(of: "^[A-Z][A-Z0-9.\\-]{0,9}$", options: .regularExpression) != nil else { return nil }
            prefix = .unitedStates
        }
        guard let prefix else { return nil }
        return MarketSymbolRoute(normalizedSymbol: normalized,
                                 metadata: metadata(for: venue, securityKind: securityKind),
                                 eastmoneySecID: EastmoneySecID(prefix: prefix, symbol: normalized))
    }

    public static func sessionStatus(_ instant: Date, for metadata: MarketVenueMetadata) -> MarketSessionStatus {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = metadata.timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: instant)
        guard let weekday = parts.weekday, let hour = parts.hour, let minute = parts.minute else {
            return .unknownHoliday
        }
        guard (2...6).contains(weekday) else { return .closedWeekend }
        guard metadata.regularSessionWindows.contains(where: { $0.contains(hour: hour, minute: minute) }) else {
            return .closedOutsideRegularSession
        }
        return .unknownHoliday
    }

    public static func localComponents(of instant: Date, in timeZone: TimeZone) -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)
    }

    public static func date(from components: DateComponents, in timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: components)
    }

    private static func aSharePrefix(for symbol: String) -> EastmoneySecIDPrefix? {
        if ["600", "601", "603", "605", "688"].contains(where: { symbol.hasPrefix($0) }) { return .shanghai }
        if ["000", "001", "002", "003", "300", "301"].contains(where: { symbol.hasPrefix($0) }) { return .shenzhen }
        return nil
    }
}

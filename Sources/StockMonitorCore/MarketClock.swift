import Foundation

public enum TradingDayStatus: Sendable, Equatable {
    case open
    case closed(reason: String)
    case unknown
}

public enum MarketClock {
    public static let timeZone = TimeZone(identifier: "Asia/Shanghai")!

    /// Each listed year's closures come from its opened official SSE annual notice.
    /// Direct SZSE cross-check coverage is recorded in SOURCE_EVIDENCE.md. Unlisted
    /// weekdays remain unknown instead of being optimistically treated as open.
    private static let officialHolidayClosures: [Int: [String: String]] = [
        2022: [
            "2022-01-03": "元旦",
            "2022-01-31": "春节", "2022-02-01": "春节", "2022-02-02": "春节",
            "2022-02-03": "春节", "2022-02-04": "春节",
            "2022-04-04": "清明节", "2022-04-05": "清明节",
            "2022-05-02": "劳动节", "2022-05-03": "劳动节", "2022-05-04": "劳动节",
            "2022-06-03": "端午节", "2022-09-12": "中秋节",
            "2022-10-03": "国庆节", "2022-10-04": "国庆节", "2022-10-05": "国庆节",
            "2022-10-06": "国庆节", "2022-10-07": "国庆节"
        ],
        2023: [
            "2023-01-02": "元旦",
            "2023-01-23": "春节", "2023-01-24": "春节", "2023-01-25": "春节",
            "2023-01-26": "春节", "2023-01-27": "春节",
            "2023-04-05": "清明节",
            "2023-05-01": "劳动节", "2023-05-02": "劳动节", "2023-05-03": "劳动节",
            "2023-06-22": "端午节", "2023-06-23": "端午节",
            "2023-09-29": "中秋节、国庆节", "2023-10-02": "中秋节、国庆节",
            "2023-10-03": "中秋节、国庆节", "2023-10-04": "中秋节、国庆节",
            "2023-10-05": "中秋节、国庆节", "2023-10-06": "中秋节、国庆节"
        ],
        2024: [
            "2024-01-01": "元旦",
            "2024-02-09": "春节", "2024-02-12": "春节", "2024-02-13": "春节",
            "2024-02-14": "春节", "2024-02-15": "春节", "2024-02-16": "春节",
            "2024-04-04": "清明节", "2024-04-05": "清明节",
            "2024-05-01": "劳动节", "2024-05-02": "劳动节", "2024-05-03": "劳动节",
            "2024-06-10": "端午节", "2024-09-16": "中秋节", "2024-09-17": "中秋节",
            "2024-10-01": "国庆节", "2024-10-02": "国庆节", "2024-10-03": "国庆节",
            "2024-10-04": "国庆节", "2024-10-07": "国庆节"
        ],
        2025: [
            "2025-01-01": "元旦",
            "2025-01-28": "春节", "2025-01-29": "春节", "2025-01-30": "春节",
            "2025-01-31": "春节", "2025-02-03": "春节", "2025-02-04": "春节",
            "2025-04-04": "清明节",
            "2025-05-01": "劳动节", "2025-05-02": "劳动节", "2025-05-05": "劳动节",
            "2025-06-02": "端午节",
            "2025-10-01": "国庆节、中秋节", "2025-10-02": "国庆节、中秋节",
            "2025-10-03": "国庆节、中秋节", "2025-10-06": "国庆节、中秋节",
            "2025-10-07": "国庆节、中秋节", "2025-10-08": "国庆节、中秋节"
        ],
        2026: [
            "2026-01-01": "元旦", "2026-01-02": "元旦",
            "2026-02-16": "春节", "2026-02-17": "春节", "2026-02-18": "春节",
            "2026-02-19": "春节", "2026-02-20": "春节", "2026-02-23": "春节",
            "2026-04-06": "清明节",
            "2026-05-01": "劳动节", "2026-05-04": "劳动节", "2026-05-05": "劳动节",
            "2026-06-19": "端午节", "2026-09-25": "中秋节",
            "2026-10-01": "国庆节", "2026-10-02": "国庆节", "2026-10-05": "国庆节",
            "2026-10-06": "国庆节", "2026-10-07": "国庆节"
        ]
    ]

    public static var verifiedCalendarYears: [Int] { officialHolidayClosures.keys.sorted() }

    public static func tradingDayStatus(_ date: Date = Date(), calendar input: Calendar? = nil) -> TradingDayStatus {
        var calendar = input ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let weekday = parts.weekday else { return .unknown }
        guard weekday != 1, weekday != 7 else { return .closed(reason: "周末") }
        guard let closures = officialHolidayClosures[year] else { return .unknown }
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        if let holiday = closures[key] { return .closed(reason: holiday) }
        return .open
    }

    public static func isTradingSession(_ date: Date = Date(), calendar input: Calendar? = nil) -> Bool {
        var calendar = input ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard case .open = tradingDayStatus(date, calendar: calendar) else { return false }
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: date)
        guard let weekday = parts.weekday, (2...6).contains(weekday),
              let hour = parts.hour, let minute = parts.minute else { return false }
        let current = hour * 60 + minute
        let morning = (9 * 60 + 15)...(11 * 60 + 30)
        let afternoon = (13 * 60)...(15 * 60)
        return morning.contains(current) || afternoon.contains(current)
    }

    public static func suggestedInterval(watchCount: Int, lowPowerMode: Bool,
                                          thermalIsElevated: Bool) -> TimeInterval {
        if lowPowerMode { return 20 }
        if thermalIsElevated { return 15 }
        switch watchCount {
        case ...15: return 3
        case 16...40: return 5
        case 41...120: return 10
        default: return 20
        }
    }
}

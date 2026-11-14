import Foundation

public enum TradingDayStatus: Sendable, Equatable {
    case open
    case closed(reason: String)
    case unknown
}

public struct OfficialHolidayClosure: Codable, Equatable, Sendable {
    public let date: String
    public let name: String

    public init(date: String, name: String) {
        self.date = date
        self.name = name
    }
}

public struct OfficialHolidayCalendarPayload: Codable, Equatable, Sendable {
    public let version: Int
    public let sourceTitle: String
    public let sourceURL: String
    public let retrievedOn: String
    public let calendarYear: Int
    public let closedDates: [OfficialHolidayClosure]

    public init(version: Int = 1, sourceTitle: String, sourceURL: String,
                retrievedOn: String, calendarYear: Int,
                closedDates: [OfficialHolidayClosure]) {
        self.version = version
        self.sourceTitle = sourceTitle
        self.sourceURL = sourceURL
        self.retrievedOn = retrievedOn
        self.calendarYear = calendarYear
        self.closedDates = closedDates
    }
}

public enum OfficialHolidayImportError: Error, Equatable, Sendable {
    case malformedPayload
    case unsupportedVersion(Int)
    case invalidProvenance(String)
    case invalidCalendarYear(Int)
    case invalidClosedDate(String)
    case duplicateClosedDate(String)
    case emptyClosedDates
    case storageLimitExceeded
}

extension OfficialHolidayImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .malformedPayload: return "交易日历 JSON 格式无效。"
        case .unsupportedVersion(let version): return "不支持交易日历格式版本 \(version)。"
        case .invalidProvenance(let reason): return "来源信息不接受：\(reason)"
        case .invalidCalendarYear(let year): return "日历年份无效：\(year)。"
        case .invalidClosedDate(let date): return "闭市日期无效：\(date)。"
        case .duplicateClosedDate(let date): return "闭市日期重复：\(date)。"
        case .emptyClosedDates: return "日历没有明示闭市日期。"
        case .storageLimitExceeded: return "交易日历文件或本机保存数据超过大小/数量上限。"
        }
    }
}

public enum MarketClock {
    public static let timeZone = TimeZone(identifier: "Asia/Shanghai")!
    private static let importedCalendarLock = NSLock()
    private static let importedCalendarPreferencesKey = "stockmonitor.officialHolidayCalendars.v1"
    private static let maximumImportedCalendarBytes = 1_048_576
    private static let maximumImportedCalendarRecords = 100
    private static var importedCalendarPayloads: [OfficialHolidayCalendarPayload] = []
    private static var importedCalendarsLoaded = false
    private static var importedHolidayClosures: [Int: [String: String]] = [:]

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

    public static var verifiedCalendarYears: [Int] {
        officialHolidayClosures.keys.sorted()
    }

    public static var calendarYearsWithEntries: [Int] {
        ensureImportedCalendarsLoaded()
        importedCalendarLock.lock()
        defer { importedCalendarLock.unlock() }
        return Set(officialHolidayClosures.keys).union(importedHolidayClosures.keys).sorted()
    }

    /// Validates and atomically merges a locally supplied official holiday record.
    /// Existing verified dates win over imported values. Imported years recognize
    /// only explicitly listed closed dates; absent dates remain unknown.
    @discardableResult
    public static func updateOfficialHolidayCalendar(with payload: OfficialHolidayCalendarPayload) throws -> OfficialHolidayCalendarPayload {
        try validate(payload)
        ensureImportedCalendarsLoaded()
        importedCalendarLock.lock()
        defer { importedCalendarLock.unlock() }
        let nextPayloads = importedCalendarPayloads.contains(payload)
            ? importedCalendarPayloads
            : importedCalendarPayloads + [payload]
        guard nextPayloads.count <= maximumImportedCalendarRecords else {
            throw OfficialHolidayImportError.storageLimitExceeded
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedPayloads = try encoder.encode(nextPayloads)
        guard encodedPayloads.count <= maximumImportedCalendarBytes else {
            throw OfficialHolidayImportError.storageLimitExceeded
        }
        var dates = importedHolidayClosures[payload.calendarYear, default: [:]]
        let verifiedDates = officialHolidayClosures[payload.calendarYear] ?? [:]
        for closure in payload.closedDates where verifiedDates[closure.date] == nil {
            dates[closure.date] = dates[closure.date] ?? closure.name
        }
        UserDefaults.standard.set(encodedPayloads, forKey: importedCalendarPreferencesKey)
        importedCalendarPayloads = nextPayloads
        importedHolidayClosures[payload.calendarYear] = dates
        return payload
    }

    /// Decodes and validates caller-supplied UTF-8 JSON. No URL or other network
    /// request is followed.
    @discardableResult
    public static func importOfficialHolidayCalendar(from data: Data) throws -> OfficialHolidayCalendarPayload {
        guard data.count <= maximumImportedCalendarBytes else {
            throw OfficialHolidayImportError.storageLimitExceeded
        }
        guard let payload = try? JSONDecoder().decode(OfficialHolidayCalendarPayload.self, from: data) else {
            throw OfficialHolidayImportError.malformedPayload
        }
        return try updateOfficialHolidayCalendar(with: payload)
    }

    #if DEBUG
    internal static func resetImportedHolidayCalendarsForTesting() {
        importedCalendarLock.lock()
        UserDefaults.standard.removeObject(forKey: importedCalendarPreferencesKey)
        importedCalendarPayloads.removeAll()
        importedCalendarsLoaded = true
        importedHolidayClosures.removeAll()
        importedCalendarLock.unlock()
    }

    internal static func reloadImportedHolidayCalendarsForTesting() {
        importedCalendarLock.lock()
        importedCalendarPayloads.removeAll()
        importedCalendarsLoaded = false
        importedHolidayClosures.removeAll()
        importedCalendarLock.unlock()
        ensureImportedCalendarsLoaded()
    }
    #endif

    private static func validate(_ payload: OfficialHolidayCalendarPayload) throws {
        guard payload.version == 1 else { throw OfficialHolidayImportError.unsupportedVersion(payload.version) }
        guard !payload.sourceTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              payload.sourceTitle.count <= 200,
              let url = URL(string: payload.sourceURL),
              url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443,
              let rawHost = url.host?.lowercased(), !rawHost.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil,
              isApprovedExchangeHost(rawHost),
              !payload.sourceURL.contains(where: { $0.isWhitespace }) else {
            throw OfficialHolidayImportError.invalidProvenance("source must be an HTTPS SSE/SZSE/BSE URL without credentials or fragments")
        }
        guard isValidISODate(payload.retrievedOn) else {
            throw OfficialHolidayImportError.invalidProvenance("retrievedOn")
        }
        guard (2000...2100).contains(payload.calendarYear) else {
            throw OfficialHolidayImportError.invalidCalendarYear(payload.calendarYear)
        }
        guard !payload.closedDates.isEmpty else { throw OfficialHolidayImportError.emptyClosedDates }
        guard payload.closedDates.count <= 366 else { throw OfficialHolidayImportError.storageLimitExceeded }

        var seen = Set<String>()
        for closure in payload.closedDates {
            guard isValidISODate(closure.date),
                  Int(closure.date.prefix(4)) == payload.calendarYear,
                  !closure.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  closure.name.count <= 80 else {
                throw OfficialHolidayImportError.invalidClosedDate(closure.date)
            }
            guard seen.insert(closure.date).inserted else {
                throw OfficialHolidayImportError.duplicateClosedDate(closure.date)
            }
        }
    }

    private static func isValidISODate(_ value: String) -> Bool {
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return false }
        let parts = value.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])) else { return false }
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return components.year == parts[0] && components.month == parts[1] && components.day == parts[2]
    }

    public static func tradingDayStatus(_ date: Date = Date(), calendar input: Calendar? = nil) -> TradingDayStatus {
        ensureImportedCalendarsLoaded()
        var calendar = input ?? Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        guard let year = parts.year, let month = parts.month, let day = parts.day,
              let weekday = parts.weekday else { return .unknown }
        guard weekday != 1, weekday != 7 else { return .closed(reason: "周末") }
        importedCalendarLock.lock()
        let closures = officialHolidayClosures[year]
        let importedClosures = importedHolidayClosures[year]
        importedCalendarLock.unlock()
        let key = String(format: "%04d-%02d-%02d", year, month, day)
        if let holiday = closures?[key] { return .closed(reason: holiday) }
        if let holiday = importedClosures?[key] { return .closed(reason: holiday) }
        if closures == nil && importedClosures != nil { return .unknown }
        guard closures != nil else { return .unknown }
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

    private static func isApprovedExchangeHost(_ host: String) -> Bool {
        let normalized = host.hasSuffix(".") ? String(host.dropLast()) : host
        let domains = ["sse.com.cn", "szse.cn", "bse.cn", "bseinfo.net"]
        return domains.contains { normalized == $0 || normalized.hasSuffix(".\($0)") }
    }

    private static func ensureImportedCalendarsLoaded() {
        importedCalendarLock.lock()
        defer { importedCalendarLock.unlock() }
        guard !importedCalendarsLoaded else { return }
        importedCalendarsLoaded = true
        guard let data = UserDefaults.standard.data(forKey: importedCalendarPreferencesKey),
              data.count <= maximumImportedCalendarBytes,
              let payloads = try? JSONDecoder().decode([OfficialHolidayCalendarPayload].self, from: data) else {
            return
        }
        var accepted: [OfficialHolidayCalendarPayload] = []
        var closures: [Int: [String: String]] = [:]
        for payload in payloads.prefix(maximumImportedCalendarRecords) {
            guard (try? validate(payload)) != nil else { continue }
            accepted.append(payload)
            let verified = officialHolidayClosures[payload.calendarYear] ?? [:]
            var yearClosures = closures[payload.calendarYear, default: [:]]
            for closure in payload.closedDates where verified[closure.date] == nil {
                yearClosures[closure.date] = yearClosures[closure.date] ?? closure.name
            }
            closures[payload.calendarYear] = yearClosures
        }
        importedCalendarPayloads = accepted
        importedHolidayClosures = closures
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

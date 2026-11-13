import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite)
import CSQLite
#else
#error("SQLite3 or the SwiftPM CSQLite system library is required")
#endif

public struct RestoredState: Sendable {
    public let watchCodes: [String]
    public let watchRules: [WatchRule]
    public let holdings: [Holding]
    public let unreadSignals: [AlertSignal]
    public let latestQuotes: [Quote]
    public let latestIndexQuotes: [Quote]
    public let lastQuoteTime: Date?
    public let lastQuoteTimeByCode: [String: Date]
    public let lastMinuteTimestampByCode: [String: Date]
    public let ruleFamilySettings: [RuleFamilySettings]
    public let ruleCheckpoint: RuleFamilyCheckpoint

    public init(watchCodes: [String], watchRules: [WatchRule] = [], holdings: [Holding] = [],
                unreadSignals: [AlertSignal], latestQuotes: [Quote] = [], latestIndexQuotes: [Quote] = [],
                lastQuoteTime: Date?, lastQuoteTimeByCode: [String: Date] = [:],
                lastMinuteTimestampByCode: [String: Date] = [:],
                ruleFamilySettings: [RuleFamilySettings] = [],
                ruleCheckpoint: RuleFamilyCheckpoint = RuleFamilyCheckpoint()) {
        self.watchCodes = watchCodes
        self.watchRules = watchRules
        self.holdings = holdings
        self.unreadSignals = unreadSignals
        self.latestQuotes = latestQuotes
        self.latestIndexQuotes = latestIndexQuotes
        self.lastQuoteTime = lastQuoteTime
        self.lastQuoteTimeByCode = lastQuoteTimeByCode
        self.lastMinuteTimestampByCode = lastMinuteTimestampByCode
        self.ruleFamilySettings = ruleFamilySettings
        self.ruleCheckpoint = ruleCheckpoint
    }
}

public protocol MonitorStore: Sendable {
    func open() async throws
    func restoreState() async throws -> RestoredState
    func setWatchCodes(_ codes: [String]) async throws
    func setRules(_ rules: [WatchRule]) async throws
    func setRuleFamilySettings(_ settings: [RuleFamilySettings]) async throws
    func setRuleCheckpoint(_ checkpoint: RuleFamilyCheckpoint) async throws
    func setHoldings(_ holdings: [Holding]) async throws
    func markSignalRead(_ id: UUID, at date: Date) async throws
    func insertQuotes(_ quotes: [Quote]) async throws
    func insertIndexQuotes(_ quotes: [Quote]) async throws
    func appendSignals(_ signals: [AlertSignal]) async throws
    func upsertEvents(_ events: [MarketEvent]) async throws
    func fetchEvents(from: Date, to: Date) async throws -> [MarketEvent]
    func searchEvents(matching query: String, limit: Int) async throws -> [MarketEvent]
    func archiveRawResponses(_ responses: [RawEventResponse], at date: Date) async throws -> Int
    func fetchRawArchive(limit: Int) async throws -> [RawResponseArchiveRecord]
    func rawArchiveStats() async throws -> RawResponseArchiveStats
    func recordSourceHealth(_ delta: SourceHealthDelta) async throws
    func fetchSourceHealth(from: Date, through: Date) async throws -> SourceHealthSnapshot
    func commitReconciliation(bars: [MinuteBar], signals: [AlertSignal]) async throws
    func commitReconciliation(bars: [MinuteBar], signals: [AlertSignal], ruleCheckpoint: RuleFamilyCheckpoint) async throws
    func commitLiveEvaluation(quotes: [Quote], indexQuotes: [Quote], bars: [MinuteBar], signals: [AlertSignal], ruleCheckpoint: RuleFamilyCheckpoint) async throws
    func fetchRecentMinuteBars(codes: [String], since: Date) async throws -> [MinuteBar]
    func fetchRecentQuotes(codes: [String], since: Date) async throws -> [Quote]
    func upsertDailyBars(_ bars: [DailyBar]) async throws
    func fetchDailyBars(codes: [String], from: Date, to: Date) async throws -> [DailyBar]
    func beginSession(at date: Date) async throws
    func endSession(at date: Date) async throws
    func checkpoint() async throws
}

public extension MonitorStore {
    func setRuleFamilySettings(_ settings: [RuleFamilySettings]) async throws {}
    func setRuleCheckpoint(_ checkpoint: RuleFamilyCheckpoint) async throws {}
    func upsertEvents(_ events: [MarketEvent]) async throws {}
    func fetchEvents(from: Date, to: Date) async throws -> [MarketEvent] { [] }
    func searchEvents(matching query: String) async throws -> [MarketEvent] {
        try await searchEvents(matching: query, limit: 50)
    }
    func searchEvents(matching query: String, limit: Int) async throws -> [MarketEvent] { [] }
    func archiveRawResponses(_ responses: [RawEventResponse]) async throws -> Int {
        try await archiveRawResponses(responses, at: Date())
    }
    func archiveRawResponses(_ responses: [RawEventResponse], at date: Date) async throws -> Int { 0 }
    func fetchRawArchive() async throws -> [RawResponseArchiveRecord] {
        try await fetchRawArchive(limit: 100)
    }
    func fetchRawArchive(limit: Int) async throws -> [RawResponseArchiveRecord] { [] }
    func rawArchiveStats() async throws -> RawResponseArchiveStats {
        RawResponseArchiveStats(responseCount: 0, byteCount: 0, oldestResponseAt: nil, newestResponseAt: nil)
    }
    func recordSourceHealth(_ delta: SourceHealthDelta) async throws {}
    func fetchSourceHealth(from: Date, through: Date) async throws -> SourceHealthSnapshot {
        SourceHealthSnapshot(from: from, through: through)
    }
    func commitReconciliation(bars: [MinuteBar], signals: [AlertSignal], ruleCheckpoint: RuleFamilyCheckpoint) async throws {
        try await commitReconciliation(bars: bars, signals: signals)
        try await setRuleCheckpoint(ruleCheckpoint)
    }
    func commitLiveEvaluation(quotes: [Quote], indexQuotes: [Quote], bars: [MinuteBar], signals: [AlertSignal], ruleCheckpoint: RuleFamilyCheckpoint) async throws {
        try await insertQuotes(quotes)
        try await insertIndexQuotes(indexQuotes)
        try await commitReconciliation(bars: bars, signals: signals, ruleCheckpoint: ruleCheckpoint)
    }
    func fetchRecentMinuteBars(codes: [String], since: Date) async throws -> [MinuteBar] { [] }
    func fetchRecentQuotes(codes: [String], since: Date) async throws -> [Quote] { [] }
    func upsertDailyBars(_ bars: [DailyBar]) async throws {}
    func fetchDailyBars(codes: [String], from: Date, to: Date) async throws -> [DailyBar] { [] }
}

public enum StoreError: Error, LocalizedError {
    case open(String)
    case statement(String)
    case encode(String)

    public var errorDescription: String? {
        switch self {
        case .open(let message): return "SQLite open failed: \(message)"
        case .statement(let message): return "SQLite statement failed: \(message)"
        case .encode(let message): return "JSON encoding failed: \(message)"
        }
    }
}

/// SQLite is confined to an actor and stays in the local app/App Group container.
public actor SQLiteMonitorStore: MonitorStore {
    private let databaseURL: URL
    private let maximumQuoteRows: Int
    private var db: OpaquePointer?
    private var rowsSincePrune = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(databaseURL: URL? = nil, appGroupIdentifier: String? = "group.com.cn00k.stockmonitorv6",
                maximumQuoteRows: Int = 250_000) {
        self.maximumQuoteRows = max(1, maximumQuoteRows)
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
#if os(iOS) || os(macOS)
            let groupContainer = appGroupIdentifier.flatMap {
                FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
            }
#else
            let groupContainer: URL? = nil
#endif
            let localContainer = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.databaseURL = (groupContainer ?? localContainer).appendingPathComponent("Monitor.sqlite", isDirectory: false)
        }
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    deinit { if let db { sqlite3_close(db) } }

    public func open() async throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            if let handle { sqlite3_close(handle) }
            throw StoreError.open(message)
        }
        db = handle
        try configureAndCreateSchema()
        try migrateSchemaIfNeeded()
        try pruneData(reference: Date())
        try pruneRawArchive(reference: Date())
    }

    public func restoreState() async throws -> RestoredState {
        try ensureOpen()
        var watchCodes: [String] = []
        try query("SELECT code FROM watchlist ORDER BY code", bind: { _ in }) { stmt in
            if let value = Self.columnText(stmt, 0) { watchCodes.append(value) }
        }
        var rules: [WatchRule] = []
        try query("SELECT payload FROM watch_rules ORDER BY id", bind: { _ in }) { stmt in
            if let payload = Self.columnText(stmt, 0), let rule = try? decoder.decode(WatchRule.self, from: Data(payload.utf8)) {
                rules.append(rule)
            }
        }
        var holdings: [Holding] = []
        try query("SELECT payload FROM positions ORDER BY code", bind: { _ in }) { stmt in
            if let payload = Self.columnText(stmt, 0), let holding = try? decoder.decode(Holding.self, from: Data(payload.utf8)) {
                holdings.append(holding)
            }
        }
        var unread: [AlertSignal] = []
        try query("SELECT payload FROM signals WHERE read_at IS NULL ORDER BY created_at DESC LIMIT 200", bind: { _ in }) { stmt in
            if let payload = Self.columnText(stmt, 0), let signal = try? decoder.decode(AlertSignal.self, from: Data(payload.utf8)) {
                unread.append(signal)
            }
        }
        let latestQuotes = try decodeLatestQuotes(table: "quotes")
        let latestIndices = try decodeLatestQuotes(table: "index_quotes")
        var lastTime: Date?
        try query("SELECT MAX(captured_at) FROM quotes", bind: { _ in }) { stmt in
            if sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                lastTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
            }
        }
        var quoteTimes: [String: Date] = [:]
        try query("SELECT code, MAX(captured_at) FROM quotes GROUP BY code", bind: { _ in }) { stmt in
            if let code = Self.columnText(stmt, 0) {
                quoteTimes[code] = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            }
        }
        var minuteTimes: [String: Date] = [:]
        try query("SELECT code, MAX(captured_at) FROM minute_bars GROUP BY code", bind: { _ in }) { stmt in
            if let code = Self.columnText(stmt, 0) {
                minuteTimes[code] = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1))
            }
        }
        var familySettings: [RuleFamilySettings] = []
        try query("SELECT payload FROM rule_settings ORDER BY family", bind: { _ in }) { stmt in
            if let payload = Self.columnText(stmt, 0),
               let setting = try? decoder.decode(RuleFamilySettings.self, from: Data(payload.utf8)) { familySettings.append(setting) }
        }
        var checkpoint = RuleFamilyCheckpoint()
        try query("SELECT payload FROM rule_state WHERE id='families'", bind: { _ in }) { stmt in
            if let payload = Self.columnText(stmt, 0),
               let restored = try? decoder.decode(RuleFamilyCheckpoint.self, from: Data(payload.utf8)) { checkpoint = restored }
        }
        return RestoredState(watchCodes: watchCodes, watchRules: rules, holdings: holdings,
            unreadSignals: unread, latestQuotes: latestQuotes, latestIndexQuotes: latestIndices,
            lastQuoteTime: lastTime, lastQuoteTimeByCode: quoteTimes,
            lastMinuteTimestampByCode: minuteTimes, ruleFamilySettings: familySettings, ruleCheckpoint: checkpoint)
    }

    public func setWatchCodes(_ codes: [String]) async throws {
        try ensureOpen()
        try transaction {
            try execute("DELETE FROM watchlist;")
            for code in Set(codes.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }).sorted()
            where code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil {
                try run("INSERT OR IGNORE INTO watchlist(code) VALUES(?)") { bindText(code, to: $0, at: 1) }
            }
        }
    }

    public func setRules(_ rules: [WatchRule]) async throws {
        try ensureOpen()
        try transaction {
            try execute("DELETE FROM watch_rules;")
            for rule in rules {
                let payload = try encodedString(rule)
                try run("INSERT OR REPLACE INTO watch_rules(id, payload) VALUES(?, ?)") { stmt in
                    bindText(rule.id, to: stmt, at: 1); bindText(payload, to: stmt, at: 2)
                }
            }
        }
    }

    public func setRuleFamilySettings(_ settings: [RuleFamilySettings]) async throws {
        try ensureOpen()
        try transaction {
            try execute("DELETE FROM rule_settings;")
            for setting in settings {
                let payload = try encodedString(setting)
                try run("INSERT OR REPLACE INTO rule_settings(family, payload) VALUES(?, ?)") { stmt in
                    bindText(setting.family.rawValue, to: stmt, at: 1)
                    bindText(payload, to: stmt, at: 2)
                }
            }
        }
    }

    public func setRuleCheckpoint(_ checkpoint: RuleFamilyCheckpoint) async throws {
        try ensureOpen()
        try transaction { try saveRuleCheckpoint(checkpoint) }
    }

    public func setHoldings(_ holdings: [Holding]) async throws {
        try ensureOpen()
        try transaction {
            try execute("DELETE FROM positions;")
            for holding in holdings where holding.code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil {
                let payload = try encodedString(holding)
                try run("INSERT OR REPLACE INTO positions(code, payload) VALUES(?, ?)") { stmt in
                    bindText(holding.code, to: stmt, at: 1); bindText(payload, to: stmt, at: 2)
                }
            }
        }
    }

    public func markSignalRead(_ id: UUID, at date: Date = Date()) async throws {
        try ensureOpen()
        try run("UPDATE signals SET read_at=? WHERE id=?") { stmt in
            sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)
            bindText(id.uuidString, to: stmt, at: 2)
        }
    }

    public func insertQuotes(_ quotes: [Quote]) async throws {
        try ensureOpen()
        guard !quotes.isEmpty else { return }
        try transaction {
            for quote in quotes where quote.kind == .stock { try insert(quote, into: "quotes") }
        }
        afterInsert(count: quotes.count, reference: quotes.map(\.timestamp).max() ?? Date())
    }

    public func insertIndexQuotes(_ quotes: [Quote]) async throws {
        try ensureOpen()
        guard !quotes.isEmpty else { return }
        try transaction {
            for quote in quotes where quote.kind == .index { try insert(quote, into: "index_quotes") }
        }
        afterInsert(count: quotes.count, reference: quotes.map(\.timestamp).max() ?? Date())
    }

    public func appendSignals(_ signals: [AlertSignal]) async throws {
        try ensureOpen()
        guard !signals.isEmpty else { return }
        try transaction { try insertSignals(signals) }
    }

    public func upsertEvents(_ events: [MarketEvent]) async throws {
        try ensureOpen()
        guard !events.isEmpty else { return }
        try transaction {
            for event in events {
                let payload = try encodedString(event)
                let eventTime = (event.publishedAt ?? event.fetchedAt).timeIntervalSince1970
                try run("INSERT OR REPLACE INTO events(id, event_time, fetched_at, source_id, priority, payload) VALUES(?, ?, ?, ?, ?, ?)") { stmt in
                    bindText(event.id, to: stmt, at: 1)
                    sqlite3_bind_double(stmt, 2, eventTime)
                    sqlite3_bind_double(stmt, 3, event.fetchedAt.timeIntervalSince1970)
                    bindText(event.sourceID, to: stmt, at: 4)
                    sqlite3_bind_int(stmt, 5, Int32(event.priority))
                    bindText(payload, to: stmt, at: 6)
                }
                try upsertEventSearchIndex(event)
            }
        }
        afterInsert(count: events.count, reference: Date())
    }

    public func fetchEvents(from: Date, to: Date) async throws -> [MarketEvent] {
        try ensureOpen()
        var events: [MarketEvent] = []
        try query("SELECT payload FROM events WHERE event_time >= ? AND event_time < ? ORDER BY event_time DESC, id ASC", bind: { stmt in
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
        }) { stmt in
            guard let payload = Self.columnText(stmt, 0),
                  let event = try? decoder.decode(MarketEvent.self, from: Data(payload.utf8)) else { return }
            events.append(event)
        }
        return events
    }

    public func searchEvents(matching queryText: String, limit: Int) async throws -> [MarketEvent] {
        try ensureOpen()
        let queryText = String(queryText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(128))
        guard !queryText.isEmpty else { return [] }
        let terms = queryText.split(whereSeparator: \.isWhitespace).map(String.init).prefix(8)
        guard !terms.isEmpty else { return [] }
        let maximum = max(1, min(100, limit))
        var result: [MarketEvent] = []
        if terms.contains(where: { $0.unicodeScalars.count < 3 }) {
            let clause = terms.map { _ in
                "(f.title LIKE ? ESCAPE '\\' OR f.body LIKE ? ESCAPE '\\' OR f.source_id LIKE ? ESCAPE '\\' OR f.stock_codes LIKE ? ESCAPE '\\' OR f.sectors LIKE ? ESCAPE '\\')"
            }.joined(separator: " AND ")
            let sql = "SELECT e.payload FROM event_fts f JOIN events e ON e.id=f.event_id WHERE e.event_time >= ? AND \(clause) ORDER BY e.event_time DESC LIMIT \(maximum)"
            try query(sql, bind: { stmt in
                sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970 - 7 * 24 * 60 * 60)
                var index: Int32 = 2
                for term in terms {
                    let escaped = Self.escapeLike(term)
                    for _ in 0..<5 {
                        self.bindText("%\(escaped)%", to: stmt, at: index)
                        index += 1
                    }
                }
            }) { stmt in
                guard let payload = Self.columnText(stmt, 0),
                      let event = try? decoder.decode(MarketEvent.self, from: Data(payload.utf8)) else { return }
                result.append(event)
            }
        } else {
            let match = terms.map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
                .joined(separator: " AND ")
            try query("SELECT e.payload FROM event_fts JOIN events e ON e.id=event_fts.event_id WHERE event_fts MATCH ? AND e.event_time >= ? ORDER BY e.event_time DESC LIMIT \(maximum)", bind: { stmt in
                self.bindText(match, to: stmt, at: 1)
                sqlite3_bind_double(stmt, 2, Date().timeIntervalSince1970 - 7 * 24 * 60 * 60)
            }) { stmt in
                guard let payload = Self.columnText(stmt, 0),
                      let event = try? decoder.decode(MarketEvent.self, from: Data(payload.utf8)) else { return }
                result.append(event)
            }
        }
        return result
    }

    @discardableResult
    public func archiveRawResponses(_ responses: [RawEventResponse], at date: Date) async throws -> Int {
        try ensureOpen()
        var accepted: [RawResponseArchiveRecord] = []
        var bytes = 0
        let retentionCutoff = date.timeIntervalSince1970 - RawResponseArchiveLimits.retention
        for response in responses {
            guard accepted.count < RawResponseArchiveLimits.maximumResponsesPerRefresh,
                  response.statusCode >= 200, response.statusCode < 300,
                  !response.sourceID.isEmpty,
                  response.fetchedAt.timeIntervalSince1970 >= retentionCutoff,
                  !response.data.isEmpty,
                  response.data.count <= RawResponseArchiveLimits.maximumResponseBytes,
                  bytes + response.data.count <= RawResponseArchiveLimits.maximumBytesPerRefresh else { continue }
            accepted.append(RawResponseArchiveRecord(id: UUID().uuidString, sourceID: response.sourceID,
                endpoint: response.sanitizedEndpoint, fetchedAt: response.fetchedAt,
                statusCode: response.statusCode, contentType: response.contentType, payload: response.data))
            bytes += response.data.count
        }
        guard !accepted.isEmpty else {
            try pruneRawArchive(reference: date)
            return 0
        }
        try transaction {
            for record in accepted {
                try run("INSERT INTO raw_archive(id, source_id, fetched_at, endpoint, status_code, content_type, byte_count, payload) VALUES(?, ?, ?, ?, ?, ?, ?, ?)") { stmt in
                    bindText(record.id, to: stmt, at: 1)
                    bindText(record.sourceID, to: stmt, at: 2)
                    sqlite3_bind_double(stmt, 3, record.fetchedAt.timeIntervalSince1970)
                    bindText(record.endpoint, to: stmt, at: 4)
                    sqlite3_bind_int(stmt, 5, Int32(record.statusCode))
                    if let contentType = record.contentType { bindText(contentType, to: stmt, at: 6) }
                    else { sqlite3_bind_null(stmt, 6) }
                    sqlite3_bind_int64(stmt, 7, sqlite3_int64(record.byteCount))
                    Self.bindBlob(record.payload, to: stmt, at: 8)
                }
            }
        }
        try pruneRawArchive(reference: date)
        return accepted.count
    }

    public func fetchRawArchive(limit: Int) async throws -> [RawResponseArchiveRecord] {
        try ensureOpen()
        try pruneRawArchive(reference: Date())
        var result: [RawResponseArchiveRecord] = []
        let maximum = max(1, min(RawResponseArchiveLimits.maximumStoredResponses, limit))
        try query("SELECT id, source_id, endpoint, fetched_at, status_code, content_type, payload FROM raw_archive ORDER BY fetched_at DESC, id DESC LIMIT \(maximum)", bind: { _ in }) { stmt in
            guard let id = Self.columnText(stmt, 0), let source = Self.columnText(stmt, 1),
                  let endpoint = Self.columnText(stmt, 2), let payload = Self.columnBlob(stmt, 6) else { return }
            result.append(RawResponseArchiveRecord(id: id, sourceID: source, endpoint: endpoint,
                fetchedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3)),
                statusCode: Int(sqlite3_column_int(stmt, 4)),
                contentType: Self.columnText(stmt, 5), payload: payload))
        }
        return result
    }

    public func rawArchiveStats() async throws -> RawResponseArchiveStats {
        try ensureOpen()
        try pruneRawArchive(reference: Date())
        var stats = RawResponseArchiveStats(responseCount: 0, byteCount: 0, oldestResponseAt: nil, newestResponseAt: nil)
        try query("SELECT COUNT(*), COALESCE(SUM(byte_count), 0), MIN(fetched_at), MAX(fetched_at) FROM raw_archive", bind: { _ in }) { stmt in
            let count = Int(sqlite3_column_int64(stmt, 0))
            let bytes = Int(sqlite3_column_int64(stmt, 1))
            let oldest = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
            let newest = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
            stats = RawResponseArchiveStats(responseCount: count, byteCount: bytes,
                oldestResponseAt: oldest, newestResponseAt: newest)
        }
        return stats
    }

    public func recordSourceHealth(_ delta: SourceHealthDelta) async throws {
        try ensureOpen()
        try run("INSERT INTO source_health_daily(day, p1_successes, p1_attempts, filter_kept, filter_total, llm_enriched, rule_or_skipped) VALUES(?, ?, ?, ?, ?, ?, ?) ON CONFLICT(day) DO UPDATE SET p1_successes=p1_successes+excluded.p1_successes, p1_attempts=p1_attempts+excluded.p1_attempts, filter_kept=filter_kept+excluded.filter_kept, filter_total=filter_total+excluded.filter_total, llm_enriched=llm_enriched+excluded.llm_enriched, rule_or_skipped=rule_or_skipped+excluded.rule_or_skipped") { stmt in
            sqlite3_bind_double(stmt, 1, delta.day.timeIntervalSince1970)
            sqlite3_bind_int64(stmt, 2, sqlite3_int64(delta.p1Successes))
            sqlite3_bind_int64(stmt, 3, sqlite3_int64(delta.p1Attempts))
            sqlite3_bind_int64(stmt, 4, sqlite3_int64(delta.filterKept))
            sqlite3_bind_int64(stmt, 5, sqlite3_int64(delta.filterTotal))
            sqlite3_bind_int64(stmt, 6, sqlite3_int64(delta.llmEnrichedDecisions))
            sqlite3_bind_int64(stmt, 7, sqlite3_int64(delta.ruleOrSkippedDecisions))
        }
    }

    public func fetchSourceHealth(from: Date, through: Date) async throws -> SourceHealthSnapshot {
        try ensureOpen()
        var values = [Int](repeating: 0, count: 6)
        try query("SELECT COALESCE(SUM(p1_successes),0), COALESCE(SUM(p1_attempts),0), COALESCE(SUM(filter_kept),0), COALESCE(SUM(filter_total),0), COALESCE(SUM(llm_enriched),0), COALESCE(SUM(rule_or_skipped),0) FROM source_health_daily WHERE day >= ? AND day <= ?", bind: { stmt in
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, through.timeIntervalSince1970)
        }) { stmt in
            for index in 0..<6 { values[index] = Int(sqlite3_column_int64(stmt, Int32(index))) }
        }
        return SourceHealthSnapshot(from: from, through: through, p1Successes: values[0], p1Attempts: values[1],
            filterKept: values[2], filterTotal: values[3], llmEnrichedDecisions: values[4],
            ruleOrSkippedDecisions: values[5])
    }

    /// Bars, signals, and evaluator state are committed together.
    public func commitReconciliation(bars: [MinuteBar], signals: [AlertSignal]) async throws {
        try ensureOpen()
        guard !bars.isEmpty || !signals.isEmpty else { return }
        try commitReconciliationTransaction(bars: bars, signals: signals, checkpoint: nil)
    }

    public func commitReconciliation(bars: [MinuteBar], signals: [AlertSignal], ruleCheckpoint: RuleFamilyCheckpoint) async throws {
        try ensureOpen()
        try commitReconciliationTransaction(bars: bars, signals: signals, checkpoint: ruleCheckpoint)
    }

    public func commitLiveEvaluation(quotes: [Quote], indexQuotes: [Quote], bars: [MinuteBar], signals: [AlertSignal], ruleCheckpoint: RuleFamilyCheckpoint) async throws {
        try ensureOpen()
        try transaction {
            for quote in quotes where quote.kind == .stock { try insert(quote, into: "quotes") }
            for quote in indexQuotes where quote.kind == .index { try insert(quote, into: "index_quotes") }
            try insertMinuteBars(bars)
            try insertSignals(signals)
            try saveRuleCheckpoint(ruleCheckpoint)
        }
        afterInsert(count: quotes.count + indexQuotes.count + bars.count, reference: Date())
    }

    public func fetchRecentMinuteBars(codes: [String], since: Date) async throws -> [MinuteBar] {
        try ensureOpen()
        let requested = Array(Set(codes)).sorted()
        guard !requested.isEmpty else { return [] }
        var result: [MinuteBar] = []
        let placeholders = Array(repeating: "?", count: requested.count).joined(separator: ",")
        try query("SELECT payload FROM minute_bars WHERE captured_at >= ? AND code IN (\(placeholders)) ORDER BY captured_at ASC, code ASC", bind: { stmt in
            sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
            for (index, code) in requested.enumerated() { bindText(code, to: stmt, at: Int32(index + 2)) }
        }) { stmt in
            guard let payload = Self.columnText(stmt, 0), let bar = try? decoder.decode(MinuteBar.self, from: Data(payload.utf8)) else { return }
            result.append(bar)
        }
        return result
    }

    public func fetchRecentQuotes(codes: [String], since: Date) async throws -> [Quote] {
        try ensureOpen()
        let requested = Array(Set(codes)).sorted()
        guard !requested.isEmpty else { return [] }
        var result: [Quote] = []
        let placeholders = Array(repeating: "?", count: requested.count).joined(separator: ",")
        for table in ["quotes", "index_quotes"] {
            try query("SELECT payload FROM \(table) WHERE captured_at >= ? AND code IN (\(placeholders)) ORDER BY captured_at ASC, code ASC", bind: { stmt in
                sqlite3_bind_double(stmt, 1, since.timeIntervalSince1970)
                for (index, code) in requested.enumerated() { bindText(code, to: stmt, at: Int32(index + 2)) }
            }) { stmt in
                guard let payload = Self.columnText(stmt, 0), let quote = try? decoder.decode(Quote.self, from: Data(payload.utf8)) else { return }
                result.append(quote)
            }
        }
        return result.sorted { $0.timestamp < $1.timestamp }
    }

    public func upsertDailyBars(_ bars: [DailyBar]) async throws {
        try ensureOpen()
        guard !bars.isEmpty else { return }
        try transaction { try insertDailyBars(bars) }
        try pruneDailyBars(reference: Date())
    }

    public func fetchDailyBars(codes: [String], from: Date, to: Date) async throws -> [DailyBar] {
        try ensureOpen()
        let requested = Array(Set(codes).sorted().prefix(200))
        guard !requested.isEmpty, from <= to else { return [] }
        var result: [DailyBar] = []
        let placeholders = Array(repeating: "?", count: requested.count).joined(separator: ",")
        try query("SELECT payload FROM daily_bars WHERE trade_date >= ? AND trade_date <= ? AND code IN (\(placeholders)) ORDER BY trade_date ASC, code ASC", bind: { stmt in
            sqlite3_bind_double(stmt, 1, from.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 2, to.timeIntervalSince1970)
            for (index, code) in requested.enumerated() { bindText(code, to: stmt, at: Int32(index + 3)) }
        }) { stmt in
            guard let payload = Self.columnText(stmt, 0),
                  let bar = try? decoder.decode(DailyBar.self, from: Data(payload.utf8)) else { return }
            result.append(bar)
        }
        return result
    }

    public func beginSession(at date: Date) async throws {
        try ensureOpen()
        try run("INSERT INTO sessions(started_at) VALUES(?)") { sqlite3_bind_double($0, 1, date.timeIntervalSince1970) }
    }

    public func endSession(at date: Date) async throws {
        try ensureOpen()
        try run("UPDATE sessions SET ended_at=? WHERE id=(SELECT MAX(id) FROM sessions WHERE ended_at IS NULL)") {
            sqlite3_bind_double($0, 1, date.timeIntervalSince1970)
        }
    }

    public func checkpoint() async throws {
        try ensureOpen()
        try execute("PRAGMA wal_checkpoint(FULL);")
    }

    private func configureAndCreateSchema() throws {
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("""
        CREATE TABLE IF NOT EXISTS watchlist(code TEXT PRIMARY KEY NOT NULL);
        CREATE TABLE IF NOT EXISTS quotes(
          code TEXT NOT NULL, captured_at REAL NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY(code, captured_at));
        CREATE INDEX IF NOT EXISTS quotes_time_idx ON quotes(captured_at);
        CREATE TABLE IF NOT EXISTS index_quotes(
          code TEXT NOT NULL, captured_at REAL NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY(code, captured_at));
        CREATE INDEX IF NOT EXISTS index_quotes_time_idx ON index_quotes(captured_at);
        CREATE TABLE IF NOT EXISTS minute_bars(
          code TEXT NOT NULL, captured_at REAL NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY(code, captured_at));
        CREATE INDEX IF NOT EXISTS minute_bars_time_idx ON minute_bars(captured_at);
        CREATE TABLE IF NOT EXISTS daily_bars(
          code TEXT NOT NULL, trade_date REAL NOT NULL, fetched_at REAL NOT NULL,
          source_id TEXT NOT NULL, payload TEXT NOT NULL,
          PRIMARY KEY(code, trade_date));
        CREATE INDEX IF NOT EXISTS daily_bars_date_idx ON daily_bars(trade_date);
        CREATE TABLE IF NOT EXISTS watch_rules(id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS rule_settings(family TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS rule_state(id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS positions(code TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS signals(
          id TEXT PRIMARY KEY NOT NULL, created_at REAL NOT NULL, read_at REAL,
          payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS signals_unread_idx ON signals(read_at, created_at DESC);
        CREATE TABLE IF NOT EXISTS events(
          id TEXT PRIMARY KEY NOT NULL, event_time REAL NOT NULL, fetched_at REAL NOT NULL,
          source_id TEXT NOT NULL, priority INTEGER NOT NULL, payload TEXT NOT NULL);
        CREATE INDEX IF NOT EXISTS events_time_idx ON events(event_time DESC);
        CREATE INDEX IF NOT EXISTS events_source_time_idx ON events(source_id, event_time DESC);
        CREATE VIRTUAL TABLE IF NOT EXISTS event_fts USING fts5(
          event_id UNINDEXED, title, body, source_id, stock_codes, sectors, tokenize='trigram');
        CREATE TRIGGER IF NOT EXISTS events_delete_fts AFTER DELETE ON events BEGIN
          DELETE FROM event_fts WHERE event_id=old.id;
        END;
        CREATE TABLE IF NOT EXISTS raw_archive(
          id TEXT PRIMARY KEY NOT NULL, source_id TEXT NOT NULL, fetched_at REAL NOT NULL,
          endpoint TEXT NOT NULL, status_code INTEGER NOT NULL, content_type TEXT,
          byte_count INTEGER NOT NULL, payload BLOB NOT NULL);
        CREATE INDEX IF NOT EXISTS raw_archive_time_idx ON raw_archive(fetched_at DESC);
        CREATE TABLE IF NOT EXISTS source_health_daily(
          day REAL PRIMARY KEY NOT NULL, p1_successes INTEGER NOT NULL DEFAULT 0,
          p1_attempts INTEGER NOT NULL DEFAULT 0, filter_kept INTEGER NOT NULL DEFAULT 0,
          filter_total INTEGER NOT NULL DEFAULT 0, llm_enriched INTEGER NOT NULL DEFAULT 0,
          rule_or_skipped INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS sessions(
          id INTEGER PRIMARY KEY AUTOINCREMENT, started_at REAL NOT NULL, ended_at REAL);
        """)
    }

    private func migrateSchemaIfNeeded() throws {
        var version = 0
        try query("PRAGMA user_version", bind: { _ in }) { stmt in
            version = Int(sqlite3_column_int(stmt, 0))
        }
        guard version < 1 else { return }
        var existing: [MarketEvent] = []
        try query("SELECT payload FROM events ORDER BY event_time ASC", bind: { _ in }) { stmt in
            guard let payload = Self.columnText(stmt, 0),
                  let event = try? decoder.decode(MarketEvent.self, from: Data(payload.utf8)) else { return }
            existing.append(event)
        }
        try transaction {
            try execute("DELETE FROM event_fts;")
            for event in existing { try insertEventSearchIndex(event) }
            try execute("PRAGMA user_version=1;")
        }
    }

    private func upsertEventSearchIndex(_ event: MarketEvent) throws {
        try run("DELETE FROM event_fts WHERE event_id=?") { bindText(event.id, to: $0, at: 1) }
        try insertEventSearchIndex(event)
    }

    private func insertEventSearchIndex(_ event: MarketEvent) throws {
        try run("INSERT INTO event_fts(event_id, title, body, source_id, stock_codes, sectors) VALUES(?, ?, ?, ?, ?, ?)") { stmt in
            bindText(event.id, to: stmt, at: 1)
            bindText(event.title, to: stmt, at: 2)
            bindText(event.body ?? "", to: stmt, at: 3)
            bindText(event.sourceID, to: stmt, at: 4)
            bindText(event.stockCodes.joined(separator: " "), to: stmt, at: 5)
            bindText(event.sectors.joined(separator: " "), to: stmt, at: 6)
        }
    }

    private func pruneRawArchive(reference: Date) throws {
        let cutoff = reference.timeIntervalSince1970 - RawResponseArchiveLimits.retention
        var rows: [(id: String, bytes: Int)] = []
        try query("SELECT id, byte_count FROM raw_archive WHERE fetched_at >= ? ORDER BY fetched_at DESC, id DESC", bind: { stmt in
            sqlite3_bind_double(stmt, 1, cutoff)
        }) { stmt in
            guard let id = Self.columnText(stmt, 0) else { return }
            rows.append((id, max(0, Int(sqlite3_column_int64(stmt, 1)))))
        }
        var keep: [String] = []
        var totalBytes = 0
        for row in rows {
            guard keep.count < RawResponseArchiveLimits.maximumStoredResponses,
                  totalBytes + row.bytes <= RawResponseArchiveLimits.maximumStoredBytes else { continue }
            keep.append(row.id)
            totalBytes += row.bytes
        }
        if keep.isEmpty {
            try execute("DELETE FROM raw_archive;")
            return
        }
        let placeholders = Array(repeating: "?", count: keep.count).joined(separator: ",")
        try run("DELETE FROM raw_archive WHERE id NOT IN (\(placeholders))") { stmt in
            for (index, id) in keep.enumerated() { bindText(id, to: stmt, at: Int32(index + 1)) }
        }
    }

    private static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    private func decodeLatestQuotes(table: String) throws -> [Quote] {
        guard table == "quotes" || table == "index_quotes" else { return [] }
        var result: [Quote] = []
        let sql = "SELECT q.payload FROM \(table) q JOIN (SELECT code, MAX(captured_at) AS ts FROM \(table) GROUP BY code) latest ON q.code=latest.code AND q.captured_at=latest.ts ORDER BY q.code"
        try query(sql, bind: { _ in }) { stmt in
            guard let payload = Self.columnText(stmt, 0),
                  let quote = try? decoder.decode(Quote.self, from: Data(payload.utf8)) else { return }
            result.append(quote)
        }
        return result
    }

    private func insert(_ quote: Quote, into table: String) throws {
        guard table == "quotes" || table == "index_quotes" else { return }
        let payload = try encodedString(quote)
        try run("INSERT OR REPLACE INTO \(table)(code, captured_at, payload) VALUES(?, ?, ?)") { stmt in
            bindText(quote.code, to: stmt, at: 1)
            sqlite3_bind_double(stmt, 2, quote.timestamp.timeIntervalSince1970)
            bindText(payload, to: stmt, at: 3)
        }
    }

    private func insertMinuteBars(_ bars: [MinuteBar]) throws {
        for bar in bars {
            let payload = try encodedString(bar)
            try run("INSERT OR REPLACE INTO minute_bars(code, captured_at, payload) VALUES(?, ?, ?)") { stmt in
                bindText(bar.code, to: stmt, at: 1)
                sqlite3_bind_double(stmt, 2, bar.timestamp.timeIntervalSince1970)
                bindText(payload, to: stmt, at: 3)
            }
        }
    }

    private func insertDailyBars(_ bars: [DailyBar]) throws {
        for bar in bars where bar.code.range(of: "^[0-9]{6}$", options: .regularExpression) != nil {
            let payload = try encodedString(bar)
            try run("INSERT OR REPLACE INTO daily_bars(code, trade_date, fetched_at, source_id, payload) VALUES(?, ?, ?, ?, ?)") { stmt in
                bindText(bar.code, to: stmt, at: 1)
                sqlite3_bind_double(stmt, 2, bar.tradeDate.timeIntervalSince1970)
                sqlite3_bind_double(stmt, 3, bar.fetchedAt.timeIntervalSince1970)
                bindText(bar.sourceID, to: stmt, at: 4)
                bindText(payload, to: stmt, at: 5)
            }
        }
    }

    private func saveRuleCheckpoint(_ checkpoint: RuleFamilyCheckpoint) throws {
        let payload = try encodedString(checkpoint)
        try run("INSERT OR REPLACE INTO rule_state(id, payload) VALUES('families', ?)") { stmt in bindText(payload, to: stmt, at: 1) }
    }

    private func commitReconciliationTransaction(bars: [MinuteBar], signals: [AlertSignal], checkpoint: RuleFamilyCheckpoint?) throws {
        try transaction {
            try insertMinuteBars(bars)
            try insertSignals(signals)
            if let checkpoint { try saveRuleCheckpoint(checkpoint) }
        }
        if !bars.isEmpty { afterInsert(count: bars.count, reference: bars.map(\.timestamp).max() ?? Date()) }
    }

    private func insertSignals(_ signals: [AlertSignal]) throws {
        for signal in signals {
            let payload = try encodedString(signal)
            try run("INSERT OR IGNORE INTO signals(id, created_at, payload) VALUES(?, ?, ?)") { stmt in
                bindText(signal.id.uuidString, to: stmt, at: 1)
                sqlite3_bind_double(stmt, 2, signal.createdAt.timeIntervalSince1970)
                bindText(payload, to: stmt, at: 3)
            }
        }
    }

    private func afterInsert(count: Int, reference: Date) {
        rowsSincePrune += count
        if rowsSincePrune >= 1_000 {
            try? pruneData(reference: reference)
            rowsSincePrune = 0
        }
    }

    private func pruneData(reference: Date) throws {
        let cutoff = reference.timeIntervalSince1970 - 7 * 24 * 60 * 60
        try execute("DELETE FROM quotes WHERE captured_at < \(cutoff) OR rowid NOT IN (SELECT rowid FROM quotes ORDER BY captured_at DESC LIMIT \(maximumQuoteRows));")
        try execute("DELETE FROM index_quotes WHERE captured_at < \(cutoff) OR rowid NOT IN (SELECT rowid FROM index_quotes ORDER BY captured_at DESC LIMIT 10000);")
        try execute("DELETE FROM minute_bars WHERE captured_at < \(cutoff) OR rowid NOT IN (SELECT rowid FROM minute_bars ORDER BY captured_at DESC LIMIT \(maximumQuoteRows));")
        try pruneDailyBars(reference: reference)
        try execute("DELETE FROM signals WHERE created_at < \(cutoff);")
        try execute("DELETE FROM events WHERE event_time < \(cutoff) OR rowid NOT IN (SELECT rowid FROM events ORDER BY event_time DESC LIMIT 100000);")
        try execute("DELETE FROM source_health_daily WHERE day < \(cutoff);")
        try execute("DELETE FROM sessions WHERE started_at < \(cutoff);")
    }

    private func pruneDailyBars(reference: Date) throws {
        let cutoff = reference.timeIntervalSince1970 - 3 * 366 * 24 * 60 * 60
        try execute("DELETE FROM daily_bars WHERE trade_date < \(cutoff) OR rowid NOT IN (SELECT rowid FROM daily_bars ORDER BY trade_date DESC LIMIT 100000);")
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE;")
        do { try body(); try execute("COMMIT;") }
        catch { try? execute("ROLLBACK;"); throw error }
    }

    private func encodedString<T: Encodable>(_ value: T) throws -> String {
        let data: Data
        do { data = try encoder.encode(value) }
        catch { throw StoreError.encode(error.localizedDescription) }
        guard let string = String(data: data, encoding: .utf8) else { throw StoreError.encode("non-UTF8 payload") }
        return string
    }

    private func ensureOpen() throws {
        if db == nil { try syncOpen() }
    }

    private func syncOpen() throws {
        guard db == nil else { return }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        let result = sqlite3_open_v2(databaseURL.path, &handle,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let handle else { throw StoreError.open("sqlite3_open_v2 returned \(result)") }
        db = handle
        try configureAndCreateSchema()
        try migrateSchemaIfNeeded()
        try pruneData(reference: Date())
        try pruneRawArchive(reference: Date())
    }

    private func execute(_ sql: String) throws {
        guard let db else { throw StoreError.open("database is not open") }
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
            sqlite3_free(message)
            throw StoreError.statement(text)
        }
    }

    private func run(_ sql: String, bind: (OpaquePointer) -> Void) throws {
        guard let db else { throw StoreError.open("database is not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.statement(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw StoreError.statement(String(cString: sqlite3_errmsg(db))) }
    }

    private func query(_ sql: String, bind: (OpaquePointer) -> Void, row: (OpaquePointer) -> Void) throws {
        guard let db else { throw StoreError.open("database is not open") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw StoreError.statement(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        bind(stmt)
        while true {
            switch sqlite3_step(stmt) {
            case SQLITE_ROW: row(stmt)
            case SQLITE_DONE: return
            default: throw StoreError.statement(String(cString: sqlite3_errmsg(db)))
            }
        }
    }

    private func bindText(_ value: String, to statement: OpaquePointer, at index: Int32) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private static func bindBlob(_ value: Data, to statement: OpaquePointer, at index: Int32) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), Self.transient)
        }
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: UnsafeRawPointer(text).assumingMemoryBound(to: CChar.self))
    }

    private static func columnBlob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

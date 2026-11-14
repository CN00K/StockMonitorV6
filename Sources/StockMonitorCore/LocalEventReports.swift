import Foundation

public struct ReportWindow: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date

    public init(id: String, title: String, start: Date, end: Date) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
    }

    public var isValid: Bool { start < end }

    public static func morning(start: Date, end: Date) -> ReportWindow {
        ReportWindow(id: "morning", title: "上午", start: start, end: end)
    }

    public static func midday(start: Date, end: Date) -> ReportWindow {
        ReportWindow(id: "midday", title: "午间", start: start, end: end)
    }
}

public struct ReportInput: Codable, Sendable, Equatable {
    public let morning: ReportWindow
    public let midday: ReportWindow
    public let events: [MarketEvent]
    public let clusters: [EventCluster]
    public let sourceStatuses: [EventSourceStatus]
    public let health: SourceHealthSnapshot?
    public let generatedAt: Date

    public init(morning: ReportWindow, midday: ReportWindow, events: [MarketEvent] = [],
                clusters: [EventCluster] = [], sourceStatuses: [EventSourceStatus] = [],
                health: SourceHealthSnapshot? = nil, generatedAt: Date) {
        self.morning = morning
        self.midday = midday
        self.events = events
        self.clusters = clusters
        self.sourceStatuses = sourceStatuses
        self.health = health
        self.generatedAt = generatedAt
    }

    public init(morningStart: Date, morningEnd: Date, middayStart: Date, middayEnd: Date,
                events: [MarketEvent] = [], clusters: [EventCluster] = [],
                sourceStatuses: [EventSourceStatus] = [], health: SourceHealthSnapshot? = nil,
                generatedAt: Date) {
        self.init(morning: .morning(start: morningStart, end: morningEnd),
                  midday: .midday(start: middayStart, end: middayEnd), events: events,
                  clusters: clusters, sourceStatuses: sourceStatuses, health: health,
                  generatedAt: generatedAt)
    }

    private enum CodingKeys: String, CodingKey {
        case morning, midday, events, clusters, sourceStatuses, health, generatedAt
    }

    private struct HealthPayload: Codable {
        let from: Date
        let through: Date
        let p1Successes: Int
        let p1Attempts: Int
        let filterKept: Int
        let filterTotal: Int
        let llmEnrichedDecisions: Int
        let ruleOrSkippedDecisions: Int

        init(_ value: SourceHealthSnapshot) {
            from = value.from; through = value.through
            p1Successes = value.p1Successes; p1Attempts = value.p1Attempts
            filterKept = value.filterKept; filterTotal = value.filterTotal
            llmEnrichedDecisions = value.llmEnrichedDecisions
            ruleOrSkippedDecisions = value.ruleOrSkippedDecisions
        }

        var snapshot: SourceHealthSnapshot {
            SourceHealthSnapshot(from: from, through: through, p1Successes: p1Successes,
                                 p1Attempts: p1Attempts, filterKept: filterKept,
                                 filterTotal: filterTotal,
                                 llmEnrichedDecisions: llmEnrichedDecisions,
                                 ruleOrSkippedDecisions: ruleOrSkippedDecisions)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        morning = try container.decode(ReportWindow.self, forKey: .morning)
        midday = try container.decode(ReportWindow.self, forKey: .midday)
        events = try container.decode([MarketEvent].self, forKey: .events)
        clusters = try container.decode([EventCluster].self, forKey: .clusters)
        sourceStatuses = try container.decode([EventSourceStatus].self, forKey: .sourceStatuses)
        health = try container.decodeIfPresent(HealthPayload.self, forKey: .health)?.snapshot
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(morning, forKey: .morning)
        try container.encode(midday, forKey: .midday)
        try container.encode(events, forKey: .events)
        try container.encode(clusters, forKey: .clusters)
        try container.encode(sourceStatuses, forKey: .sourceStatuses)
        try container.encodeIfPresent(health.map(HealthPayload.init), forKey: .health)
        try container.encode(generatedAt, forKey: .generatedAt)
    }
}

public enum ReportDataState: String, Codable, Sendable, Equatable {
    case data
    case partial
    case noData
}

public struct ReportEventSummary: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let publishedAt: Date
    public let priority: Int
    public let sectors: [String]
    public let stockCodes: [String]

    public init(event: MarketEvent) {
        id = event.id
        title = event.title
        publishedAt = event.publishedAt ?? event.fetchedAt
        priority = event.priority
        sectors = event.sectors.sorted()
        stockCodes = event.stockCodes.sorted()
    }
}

public struct ReportWindowModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let eventCount: Int
    public let clusterCount: Int
    public let priorityCounts: [Int: Int]
    public let sectorCounts: [String: Int]
    public let events: [ReportEventSummary]

    public var isNoData: Bool { eventCount == 0 && clusterCount == 0 }

    public init(window: ReportWindow, eventCount: Int, clusterCount: Int,
                priorityCounts: [Int: Int], sectorCounts: [String: Int],
                events: [ReportEventSummary] = []) {
        self.id = window.id
        self.title = window.title
        self.start = window.start
        self.end = window.end
        self.eventCount = eventCount
        self.clusterCount = clusterCount
        self.priorityCounts = priorityCounts
        self.sectorCounts = sectorCounts
        self.events = events
    }
}

public struct ReportCoverage: Codable, Sendable, Equatable {
    public let sourceCount: Int
    public let successfulSourceCount: Int
    public let failedSourceIDs: [String]
    public let warnings: [String]
    public let health: SourceHealthSnapshot?

    public init(sourceCount: Int, successfulSourceCount: Int, failedSourceIDs: [String],
                warnings: [String], health: SourceHealthSnapshot?) {
        self.sourceCount = sourceCount
        self.successfulSourceCount = successfulSourceCount
        self.failedSourceIDs = failedSourceIDs
        self.warnings = warnings
        self.health = health
    }

    private enum CodingKeys: String, CodingKey {
        case sourceCount, successfulSourceCount, failedSourceIDs, warnings, health
    }

    private struct HealthPayload: Codable {
        let from: Date
        let through: Date
        let p1Successes: Int
        let p1Attempts: Int
        let filterKept: Int
        let filterTotal: Int
        let llmEnrichedDecisions: Int
        let ruleOrSkippedDecisions: Int

        init(_ value: SourceHealthSnapshot) {
            from = value.from; through = value.through
            p1Successes = value.p1Successes; p1Attempts = value.p1Attempts
            filterKept = value.filterKept; filterTotal = value.filterTotal
            llmEnrichedDecisions = value.llmEnrichedDecisions
            ruleOrSkippedDecisions = value.ruleOrSkippedDecisions
        }

        var snapshot: SourceHealthSnapshot {
            SourceHealthSnapshot(from: from, through: through, p1Successes: p1Successes,
                                 p1Attempts: p1Attempts, filterKept: filterKept,
                                 filterTotal: filterTotal,
                                 llmEnrichedDecisions: llmEnrichedDecisions,
                                 ruleOrSkippedDecisions: ruleOrSkippedDecisions)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sourceCount = try container.decode(Int.self, forKey: .sourceCount)
        successfulSourceCount = try container.decode(Int.self, forKey: .successfulSourceCount)
        failedSourceIDs = try container.decode([String].self, forKey: .failedSourceIDs)
        warnings = try container.decode([String].self, forKey: .warnings)
        health = try container.decodeIfPresent(HealthPayload.self, forKey: .health)?.snapshot
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sourceCount, forKey: .sourceCount)
        try container.encode(successfulSourceCount, forKey: .successfulSourceCount)
        try container.encode(failedSourceIDs, forKey: .failedSourceIDs)
        try container.encode(warnings, forKey: .warnings)
        try container.encodeIfPresent(health.map(HealthPayload.init), forKey: .health)
    }
}

public struct ReportModel: Codable, Sendable, Equatable {
    public let generatedAt: Date
    public let state: ReportDataState
    public let windows: [ReportWindowModel]
    public let coverage: ReportCoverage

    public init(generatedAt: Date, state: ReportDataState, windows: [ReportWindowModel],
                coverage: ReportCoverage) {
        self.generatedAt = generatedAt
        self.state = state
        self.windows = windows
        self.coverage = coverage
    }

    public func markdown() -> String { ReportBuilder.markdown(self) }
}

public struct ReportBuilder: Sendable {
    public init() {}

    public func build(_ input: ReportInput) -> ReportModel {
        let windows = [input.morning, input.midday].map { window in
            let events = input.events.filter { event in
                let date = event.publishedAt ?? event.fetchedAt
                return date >= window.start && date < window.end
            }
            let eventIDs = Set(events.map(\.id))
            let selectedClusters = input.clusters.filter { cluster in
                let dates = [cluster.firstPublishedAt, cluster.latestPublishedAt].compactMap { $0 }
                if dates.contains(where: { $0 >= window.start && $0 < window.end }) { return true }
                return !Set(cluster.eventIDs).isDisjoint(with: eventIDs)
            }
            var priorities: [Int: Int] = [:]
            var sectors: [String: Int] = [:]
            for event in events {
                priorities[event.priority, default: 0] += 1
                for sector in event.sectors { sectors[sector, default: 0] += 1 }
            }
            return ReportWindowModel(window: window, eventCount: events.count,
                                     clusterCount: selectedClusters.count,
                                     priorityCounts: priorities, sectorCounts: sectors,
                                     events: events.map(ReportEventSummary.init(event:)).sorted {
                                         $0.publishedAt == $1.publishedAt ? $0.id < $1.id : $0.publishedAt > $1.publishedAt
                                     })
        }
        let failed = input.sourceStatuses.filter { $0.error != nil }.map(\.sourceID).sorted()
        var warnings = input.sourceStatuses.flatMap { status -> [String] in
            var result: [String] = []
            if let error = status.error { result.append("\(status.sourceID): \(error)") }
            if let note = status.note { result.append("\(status.sourceID): \(note)") }
            if status.requestCount == 0 { result.append("\(status.sourceID): no request made") }
            return result
        }
        if !input.morning.isValid { warnings.append("morning: invalid time window") }
        if !input.midday.isValid { warnings.append("midday: invalid time window") }
        warnings = Array(Set(warnings)).sorted()
        let successful = input.sourceStatuses.filter { $0.error == nil }.count
        let coverage = ReportCoverage(sourceCount: input.sourceStatuses.count,
                                      successfulSourceCount: successful,
                                      failedSourceIDs: failed, warnings: warnings,
                                      health: input.health)
        let hasData = windows.contains { !$0.isNoData }
        let isPartial = !failed.isEmpty || !warnings.isEmpty ||
            (coverage.sourceCount > 0 && successful < coverage.sourceCount)
        return ReportModel(generatedAt: input.generatedAt,
                           state: hasData ? (isPartial ? .partial : .data) : .noData,
                           windows: windows, coverage: coverage)
    }

    public static func markdown(_ report: ReportModel) -> String {
        var lines = ["# 本地资讯时段报告", "", "生成时间（上海）：\(date(report.generatedAt))", "",
                     "数据状态：\(stateTitle(report.state))", ""]
        for window in report.windows.sorted(by: stableWindowOrder) {
            lines += ["## \(escape(window.title))", "",
                      "时段：`\(date(window.start))` – `\(date(window.end))`（左闭右开）",
                      "事件数：\(window.eventCount)", "主题簇数：\(window.clusterCount)", ""]
            lines.append("内部优先级计数：" + (window.priorityCounts.keys.sorted().map { "\($0)=\(window.priorityCounts[$0] ?? 0)" }.joined(separator: "，").nilIfEmpty ?? "无"))
            let sectors = window.sectorCounts.keys.sorted().map { "\(escape($0))=\(window.sectorCounts[$0] ?? 0)" }
            lines.append("涉及行业：" + (sectors.joined(separator: "，").nilIfEmpty ?? "无"))
            if !window.events.isEmpty {
                lines.append("")
                lines.append("### 事件详情")
                for event in window.events {
                    var detail = "- \(date(event.publishedAt)) · 内部优先级 \(event.priority) · \(escape(event.title))"
                    if !event.stockCodes.isEmpty { detail += " · 证券代码：\(event.stockCodes.map(escape).joined(separator: "、"))" }
                    if !event.sectors.isEmpty { detail += " · 行业：\(event.sectors.map(escape).joined(separator: "、"))" }
                    lines.append(detail)
                }
            }
            lines.append("")
        }
        lines += ["## 来源覆盖", "", "成功来源：\(report.coverage.successfulSourceCount)/\(report.coverage.sourceCount)"]
        if report.coverage.failedSourceIDs.isEmpty { lines.append("失败来源：无") }
        else { lines.append("失败来源：" + report.coverage.failedSourceIDs.sorted().map(escape).joined(separator: "、")) }
        if report.coverage.warnings.isEmpty { lines.append("采集提示：无") }
        else {
            lines.append("采集提示：")
            lines.append(contentsOf: report.coverage.warnings.sorted().map { "- \(escape($0))" })
        }
        lines += ["", "说明：仅依据本机已保存事件及来源状态；缺失数据不会补造。本报告不构成投资建议。", ""]
        if report.state == .noData { lines += ["## 暂无数据", "", "所选时段内没有本机已保存的事件或主题簇。", ""] }
        return lines.joined(separator: "\n")
    }

    private static func stateTitle(_ state: ReportDataState) -> String {
        switch state {
        case .data: return "有数据"
        case .partial: return "部分数据"
        case .noData: return "暂无数据"
        }
    }

    private static func stableWindowOrder(_ lhs: ReportWindowModel, _ rhs: ReportWindowModel) -> Bool {
        lhs.start == rhs.start ? lhs.id < rhs.id : lhs.start < rhs.start
    }

    private static func date(_ value: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = MarketClock.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: value)
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "_", with: "\\_")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

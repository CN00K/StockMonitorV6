import Foundation

public enum EventExportFormat: String, Codable, Sendable {
    case csv
    case json
}

public enum EventExportError: Error, LocalizedError {
    case encoding(String)

    public var errorDescription: String? {
        switch self {
        case .encoding(let reason): return "Event export failed: \(reason)"
        }
    }
}

public enum EventExporter {
    public static func encode(events: [MarketEvent], format: EventExportFormat) throws -> Data {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do { return try encoder.encode(events.sorted(by: exportOrder)) }
            catch { throw EventExportError.encoding(error.localizedDescription) }
        case .csv:
            let lines = [
                ["id", "kind", "source_id", "source_item_id", "priority", "title", "body", "url",
                 "published_at", "latest_published_at", "fetched_at", "provider_timestamp_verified",
                 "impact_scope", "sectors", "stock_codes", "duplicate_count", "corroborating_sources"].map(csvField).joined(separator: ",")
            ] + events.sorted(by: exportOrder).map { event in
                [event.id, event.kind.rawValue, event.sourceID, event.sourceItemID ?? "",
                 String(event.priority), event.title, event.body ?? "", event.url ?? "",
                 iso(event.publishedAt), iso(event.latestPublishedAt), iso(event.fetchedAt),
                 event.providerTimestampVerified ? "true" : "false", event.impactScope.rawValue,
                 event.sectors.joined(separator: "|"), event.stockCodes.joined(separator: "|"),
                 String(event.duplicateCount), event.corroboratingSources.joined(separator: "|")]
                    .map(csvField).joined(separator: ",")
            }
            return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        }
    }

    /// Writes a uniquely named file under the local temporary directory for a ShareLink.
    public static func writeTemporaryFile(events: [MarketEvent], format: EventExportFormat,
                                          directory: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let data = try encode(events: events, format: format)
        let file = directory.appendingPathComponent("stock-monitor-events-\(UUID().uuidString).\(format.rawValue)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            return file
        } catch {
            throw EventExportError.encoding(error.localizedDescription)
        }
    }

    private static func exportOrder(_ lhs: MarketEvent, _ rhs: MarketEvent) -> Bool {
        let left = lhs.publishedAt ?? lhs.fetchedAt
        let right = rhs.publishedAt ?? rhs.fetchedAt
        return left == right ? lhs.id < rhs.id : left > right
    }

    private static func iso(_ date: Date?) -> String {
        guard let date else { return "" }
        return ISO8601DateFormatter().string(from: date)
    }

    private static func csvField(_ field: String) -> String {
        let startsWithFormula = field.drop(while: { $0.isWhitespace }).first.map { "=+-@".contains($0) } ?? false
        let safeField = startsWithFormula ? "'\(field)" : field
        return "\"\(safeField.replacingOccurrences(of: "\"", with: "\"\""))\""
    }
}

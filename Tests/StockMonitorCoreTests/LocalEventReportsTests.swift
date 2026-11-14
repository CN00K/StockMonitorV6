import Foundation
import XCTest
@testable import StockMonitorCore

final class LocalEventReportsTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ id: String, at offset: TimeInterval, title: String = "标题", priority: Int = 3,
                       sectors: [String] = ["银行"]) -> MarketEvent {
        let date = base.addingTimeInterval(offset)
        return MarketEvent(id: id, sourceID: "source", title: title, publishedAt: date,
                           fetchedAt: date, priority: priority, sectors: sectors)
    }

    private func input(events: [MarketEvent], statuses: [EventSourceStatus] = []) -> ReportInput {
        ReportInput(morningStart: base, morningEnd: base.addingTimeInterval(3600),
                    middayStart: base.addingTimeInterval(3600), middayEnd: base.addingTimeInterval(7200),
                    events: events, sourceStatuses: statuses, generatedAt: base)
    }

    func testHalfOpenBoundariesAndEventClusterCounts() {
        let inside = event("inside", at: 0)
        let boundary = event("boundary", at: 3600)
        let cluster = EventCluster(id: "cluster", headline: "headline", eventCount: 2, priority: 3,
                                   sourceIDs: ["source"], sectors: ["银行"], stockCodes: [],
                                   firstPublishedAt: base, latestPublishedAt: base,
                                   eventIDs: ["inside"])
        let report = ReportBuilder().build(ReportInput(morning: .morning(start: base, end: base.addingTimeInterval(3600)),
            midday: .midday(start: base.addingTimeInterval(3600), end: base.addingTimeInterval(7200)),
            events: [inside, boundary], clusters: [cluster], generatedAt: base))
        XCTAssertEqual(report.windows[0].eventCount, 1)
        XCTAssertEqual(report.windows[0].clusterCount, 1)
        XCTAssertEqual(report.windows[1].eventCount, 1)
    }

    func testNoDataAndPartialCoverageAreExplicit() {
        let empty = ReportBuilder().build(input(events: []))
        XCTAssertEqual(empty.state, .noData)
        XCTAssertTrue(empty.markdown().contains("## 暂无数据"))

        let failed = EventSourceStatus(sourceID: "z-source", requestedCount: 1, returnedCount: 0,
                                       requestCount: 1, error: "offline <bad>", note: "retry")
        let partial = ReportBuilder().build(input(events: [event("one", at: 10)], statuses: [failed]))
        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.coverage.failedSourceIDs, ["z-source"])
        XCTAssertTrue(partial.coverage.warnings.contains("z-source: offline <bad>"))
    }

    func testMarkdownUsesChineseHeadingsAndShanghaiTimestamps() {
        let report = ReportBuilder().build(input(events: [event("one", at: 5)]))
        let markdown = report.markdown()
        XCTAssertTrue(markdown.hasPrefix("# 本地资讯时段报告"))
        XCTAssertTrue(markdown.contains("生成时间（上海）："))
        XCTAssertTrue(markdown.contains("## 上午"))
        XCTAssertTrue(markdown.contains("事件数：1"))
        XCTAssertTrue(markdown.contains("本报告不构成投资建议"))
    }

    func testStableSortingAndMarkdownEscaping() {
        let dangerous = event("a", at: 20, title: "[x](javascript:alert(1)) `code` <tag>\nnext", sectors: ["[sector]"])
        let normal = event("b", at: 10, title: "normal", sectors: ["A", "B"])
        let report = ReportBuilder().build(input(events: [dangerous, normal]))
        let first = report.markdown()
        let second = report.markdown()
        XCTAssertEqual(first, second)
        XCTAssertFalse(first.contains("[x](javascript:"))
        XCTAssertTrue(first.contains("\\[x\\]\\(javascript:alert\\(1\\)\\)"))
        XCTAssertTrue(first.contains("&lt;tag&gt;"))
        XCTAssertTrue(first.contains("\\`code\\`"))
        XCTAssertTrue(first.range(of: "A=1")!.lowerBound < first.range(of: "B=1")!.lowerBound)
    }

    func testCodableRoundTripWithHealth() throws {
        let health = SourceHealthSnapshot(from: base, through: base.addingTimeInterval(60),
                                          p1Successes: 2, p1Attempts: 3, filterKept: 4, filterTotal: 5)
        let original = ReportInput(morningStart: base, morningEnd: base.addingTimeInterval(3600),
            middayStart: base.addingTimeInterval(3600), middayEnd: base.addingTimeInterval(7200),
            events: [event("one", at: 5)], health: health, generatedAt: base)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ReportInput.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testPDFExportIsDeterministicAndContainsReportContent() throws {
        let report = ReportBuilder().build(input(events: [event("one", at: 5, title: "Plain title")]))
        let first = try LocalReportExporter.export(report: report)
        let second = try LocalReportExporter.export(report: report)
        XCTAssertTrue(report.markdown().contains("# 本地资讯时段报告"))

#if canImport(UIKit)
        XCTAssertTrue(first.starts(with: Data("%PDF".utf8)))
        XCTAssertGreaterThan(first.count, 256)
        XCTAssertTrue(second.starts(with: Data("%PDF".utf8)))
#else
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.starts(with: Data("%PDF-1.4".utf8)))
        XCTAssertTrue(String(decoding: first, as: UTF8.self).contains("Plain title"))
        XCTAssertTrue(String(decoding: first, as: UTF8.self).hasSuffix("%%EOF\n"))
#endif
    }

    func testPDFExportIncludesNoDataAndEscapesPDFDelimiters() throws {
        let empty = ReportBuilder().build(input(events: []))
        let emptyPDF = String(decoding: try LocalReportExporter.export(report: empty), as: UTF8.self)
        XCTAssertTrue(empty.markdown().contains("## 暂无数据"))
#if canImport(UIKit)
        XCTAssertTrue(emptyPDF.hasPrefix("%PDF"))
#else
        XCTAssertTrue(emptyPDF.hasPrefix("%PDF-1.4"))
#endif

        let markdown = "# Report (safe)\\\\\nvalue (x)"
        let pdf = String(decoding: try LocalReportExporter.export(markdown: markdown), as: UTF8.self)
#if canImport(UIKit)
        XCTAssertTrue(pdf.hasPrefix("%PDF"))
#else
        XCTAssertTrue(pdf.contains("\\(safe\\)"))
        XCTAssertTrue(pdf.contains("value \\(x\\)"))
#endif
    }

    func testPDFIsTheOnlyClaimedAndAvailableFormat() throws {
        XCTAssertEqual(LocalReportExporter.supportedFormats, [.pdf])
        XCTAssertTrue(LocalReportExporter.isSupported(.pdf))
        #if os(Linux)
        XCTAssertTrue(LocalReportExporter.isSupported(.pdf))
        #endif
    }
}

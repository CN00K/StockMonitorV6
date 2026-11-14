import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Formats supported by the local report exporter.
public enum LocalReportExportFormat: String, Codable, Sendable, Equatable {
    case pdf
}

public enum LocalReportExportError: Error, LocalizedError, Sendable, Equatable {
    case unsupported(format: String)
    case invalidMarkdown

    public var errorDescription: String? {
        switch self {
        case .unsupported(let format): return "Local report export format is unsupported: \(format)"
        case .invalidMarkdown: return "Local report Markdown cannot be rendered"
        }
    }
}

/// Deterministic, network-free export of a built local event report.
///
/// Apple platforms render Unicode using the system font (including Chinese glyphs).
/// The dependency-free Linux test renderer uses built-in Helvetica and substitutes
/// unsupported WinAnsi characters; the original Markdown remains lossless.
public enum LocalReportExporter {
    public static let supportedFormats: [LocalReportExportFormat] = [.pdf]

    public static func isSupported(_ format: LocalReportExportFormat) -> Bool {
        supportedFormats.contains(format)
    }

    public static func export(report: ReportModel, format: LocalReportExportFormat = .pdf) throws -> Data {
        try export(markdown: report.markdown(), format: format)
    }

    public static func export(markdown: String, format: LocalReportExportFormat = .pdf) throws -> Data {
        guard isSupported(format) else { throw LocalReportExportError.unsupported(format: format.rawValue) }
        guard !markdown.contains("\0") else { throw LocalReportExportError.invalidMarkdown }
        return PDFDocument(markdown: markdown).data()
    }

    public static func write(report: ReportModel, to url: URL,
                             format: LocalReportExportFormat = .pdf) throws {
        let data = try export(report: report, format: format)
        try data.write(to: url, options: .atomic)
    }
}

private struct PDFDocument {
    private let lines: [String]
    private let pageWidth = 612
    private let pageHeight = 792
    private let left = 54
    private let top = 738
    private let lineHeight = 14
    private let charactersPerLine = 92
    private let linesPerPage = 48

    init(markdown: String) {
        var result: [String] = []
        for sourceLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(sourceLine).hasSuffix("\r") ? String(String(sourceLine).dropLast()) : String(sourceLine)
            if line.isEmpty { result.append("") }
            else {
                var remaining = line
                while remaining.count > charactersPerLine {
                    let index = remaining.index(remaining.startIndex, offsetBy: charactersPerLine)
                    result.append(String(remaining[..<index]))
                    remaining = String(remaining[index...])
                }
                result.append(remaining)
            }
        }
        self.lines = result.isEmpty ? [""] : result
    }

    func data() -> Data {
#if canImport(UIKit)
        return applePDFData()
#else
        let pageLines = stride(from: 0, to: lines.count, by: linesPerPage).map {
            Array(lines[$0..<min($0 + linesPerPage, lines.count)])
        }
        var objects: [String] = []
        objects.append("<< /Type /Catalog /Pages 2 0 R >>")
        let pageObjectIDs = pageLines.indices.map { 3 + ($0 * 2) }
        let kids = pageObjectIDs.map { "\($0) 0 R" }.joined(separator: " ")
        objects.append("<< /Type /Pages /Count \(pageLines.count) /Kids [\(kids)] >>")
        for pageIndex in pageLines.indices {
            let pageID = 3 + pageIndex * 2
            let contentID = pageID + 1
            let content = pageContent(pageLines[pageIndex])
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageWidth) \(pageHeight)] /Resources << /Font << /F1 \(3 + pageLines.count * 2) 0 R >> >> /Contents \(contentID) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")

        var output = Data("%PDF-1.4\n%\u{E2}\u{E3}\u{CF}\u{D3}\n".utf8)
        var offsets = [Int](repeating: 0, count: objects.count + 1)
        for (index, object) in objects.enumerated() {
            let id = index + 1
            offsets[id] = output.count
            output.append(contentsOf: Data("\(id) 0 obj\n\(object)\nendobj\n".utf8))
        }
        let xref = output.count
        output.append(contentsOf: Data("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8))
        for offset in offsets.dropFirst() {
            output.append(contentsOf: Data(String(format: "%010d 00000 n \n", offset).utf8))
        }
        output.append(contentsOf: Data("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n".utf8))
        return output
#endif
    }

#if canImport(UIKit)
    private func applePDFData() -> Data {
        let pageBounds = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        let font = UIFont.systemFont(ofSize: 11)
        let availableWidth = pageBounds.width - CGFloat(left * 2)
        let wrapped = lines.flatMap { wrap($0, font: font, width: availableWidth) }
        let visibleLineCount = max(1, Int((pageBounds.height - CGFloat(left * 2)) / CGFloat(lineHeight)))
        let pages = stride(from: 0, to: wrapped.count, by: visibleLineCount).map {
            Array(wrapped[$0..<min($0 + visibleLineCount, wrapped.count)])
        }
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.black
        ]
        return renderer.pdfData { context in
            for page in pages {
                context.beginPage()
                var y = CGFloat(left)
                for line in page {
                    (line as NSString).draw(at: CGPoint(x: CGFloat(left), y: y), withAttributes: attributes)
                    y += CGFloat(lineHeight)
                }
            }
        }
    }

    private func wrap(_ line: String, font: UIFont, width: CGFloat) -> [String] {
        guard !line.isEmpty else { return [""] }
        let attributes: [NSAttributedString.Key: Any] = [.font: font]
        var result: [String] = []
        var current = ""
        for character in line {
            let next = current + String(character)
            if !current.isEmpty && (next as NSString).size(withAttributes: attributes).width > width {
                result.append(current)
                current = String(character)
            } else {
                current = next
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
#endif

    private func pageContent(_ pageLines: [String]) -> String {
        var content = ["BT", "/F1 11 Tf", "\(left) \(top) Td"]
        for (index, line) in pageLines.enumerated() {
            if index > 0 { content.append("0 -\(lineHeight) Td") }
            content.append("(\(pdfEscape(line))) Tj")
        }
        content.append("ET")
        return content.joined(separator: "\n")
    }

    private func pdfEscape(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            switch scalar.value {
            case 9: return "\\t"
            case 32...126:
                if scalar.value == 92 || scalar.value == 40 || scalar.value == 41 {
                    return "\\\(String(scalar))"
                }
                return String(scalar)
            default: return "?"
            }
        }.joined()
    }
}

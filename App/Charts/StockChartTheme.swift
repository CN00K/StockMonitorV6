import Foundation
import SwiftUI
import StockMonitorCore

struct StockChartTheme {
    let grid: Color
    let axisLabel: Color
    let crosshair: Color
    let priceUp: Color
    let priceDown: Color
    let priceFlat: Color
    let volumeUp: Color
    let volumeDown: Color
    let flowIn: Color
    let flowOut: Color
    let heatScale: [Color]

    init(palette: StockMonitorPalette) {
        grid = palette.hair.opacity(StockMonitorTokens.Opacity.chartGrid)
        axisLabel = palette.inkMuted
        crosshair = palette.accent2
        priceUp = palette.dataUp
        priceDown = palette.dataDown
        priceFlat = palette.dataFlat
        volumeUp = palette.dataUp.opacity(StockMonitorTokens.Opacity.volumeBar)
        volumeDown = palette.dataDown.opacity(StockMonitorTokens.Opacity.volumeBar)
        flowIn = palette.flowIn
        flowOut = palette.flowOut
        heatScale = palette.heatScale
    }

    static func heatColor(for value: Double,
                          reference: [Double],
                          palette: StockMonitorPalette) -> Color? {
        guard let bucket = VisualizationMapping.quantileBucket(for: value, reference: reference),
              palette.heatScale.indices.contains(bucket) else { return nil }
        return palette.heatScale[bucket]
    }
}

struct StockThresholdRail: View {
    let value: Double
    let threshold: Double
    let minimum: Double
    let maximum: Double
    let accessibilityDescription: String
    @Environment(\.stockMonitorPalette) private var palette

    var body: some View {
        GeometryReader { proxy in
            let valuePosition = VisualizationMapping.thresholdPosition(value, minimum: minimum, maximum: maximum)
            let thresholdPosition = VisualizationMapping.thresholdPosition(threshold, minimum: minimum, maximum: maximum)
            ZStack {
                Capsule().fill(palette.paper2)
                if let thresholdPosition {
                    Rectangle()
                        .fill(palette.accent2)
                        .frame(width: StockMonitorTokens.Size.hairline, height: proxy.size.height)
                        .position(x: proxy.size.width * thresholdPosition, y: proxy.size.height / 2)
                }
                if let valuePosition {
                    Circle()
                        .fill(palette.accent)
                        .overlay(Circle().stroke(palette.paper1, lineWidth: StockMonitorTokens.Size.hairline))
                        .frame(width: StockMonitorTokens.Size.thresholdMarkerDiameter,
                               height: StockMonitorTokens.Size.thresholdMarkerDiameter)
                        .position(x: StockMonitorTokens.Size.thresholdMarkerDiameter / 2
                                  + (proxy.size.width - StockMonitorTokens.Size.thresholdMarkerDiameter) * valuePosition,
                                  y: proxy.size.height / 2)
                }
            }
        }
        .frame(height: StockMonitorTokens.Size.thresholdRailHeight)
        .accessibilityElement()
        .accessibilityLabel(Text(accessibilityDescription))
    }
}

enum ChartFormatters {
    private static let zhCN = Locale(identifier: "zh_CN")
    private static let chinaTimeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current

    static func price(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        return "¥\(decimal(value, digits: 2, grouping: false))"
    }

    /// Input is a decimal fraction: 0.012 means +1.20%.
    static func percent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        let formatter = NumberFormatter()
        formatter.locale = zhCN
        formatter.numberStyle = .percent
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "n/a"
    }

    static func signedPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        let sign = value > 0 ? "+" : value < 0 ? "−" : ""
        return sign + percent(abs(value))
    }

    static func cnyAmount(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        let magnitude = abs(value)
        if magnitude >= 100_000_000 {
            return "\(signedDecimal(value / 100_000_000, digits: 2)) 亿元"
        }
        if magnitude >= 10_000 {
            return "\(signedDecimal(value / 10_000, digits: 2)) 万元"
        }
        return "\(signedDecimal(value, digits: 2)) 元"
    }

    static func unsignedCNYAmount(_ value: Double?) -> String {
        guard let value, value.isFinite, value >= 0 else { return "未知" }
        if value >= 100_000_000 {
            return "\(decimal(value / 100_000_000, digits: 2, grouping: true)) 亿元"
        }
        if value >= 10_000 {
            return "\(decimal(value / 10_000, digits: 2, grouping: true)) 万元"
        }
        return "\(decimal(value, digits: 2, grouping: true)) 元"
    }

    static func shareVolume(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "n/a" }
        let magnitude = abs(value)
        if magnitude >= 100_000_000 { return "\(signedDecimal(value / 100_000_000, digits: 2)) 亿股" }
        if magnitude >= 10_000 { return "\(signedDecimal(value / 10_000, digits: 2)) 万股" }
        return "\(signedDecimal(value, digits: 0)) 股"
    }

    static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = zhCN
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    static func dateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = zhCN
        formatter.timeZone = chinaTimeZone
        formatter.dateFormat = "M/d HH:mm"
        return formatter.string(from: date)
    }

    private static func decimal(_ value: Double, digits: Int, grouping: Bool) -> String {
        let formatter = NumberFormatter()
        formatter.locale = zhCN
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = grouping
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: NSNumber(value: value)) ?? "n/a"
    }

    private static func signedDecimal(_ value: Double, digits: Int) -> String {
        let prefix = value > 0 ? "+" : value < 0 ? "−" : ""
        return prefix + decimal(abs(value), digits: digits, grouping: true)
    }
}

enum StockMonitorDirection: Equatable {
    case up, down, flat

    var symbol: String {
        switch self {
        case .up: "arrow.up.right"
        case .down: "arrow.down.right"
        case .flat: "minus"
        }
    }
}

struct StockMonitorChangeBadge: View {
    @Environment(\.stockMonitorPalette) private var palette
    let direction: StockMonitorDirection
    let valueText: String

    private var tint: Color {
        switch direction {
        case .up: palette.dataUp
        case .down: palette.dataDown
        case .flat: palette.dataFlat
        }
    }

    var body: some View {
        HStack(spacing: StockMonitorTokens.Space.xsmall) {
            Image(systemName: direction.symbol)
                .accessibilityHidden(true)
            Text(valueText).monospacedDigit()
        }
        .font(.system(size: StockMonitorTokens.TypeScale.footnote, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, StockMonitorTokens.Space.medium)
        .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
        .background(tint.opacity(StockMonitorTokens.Opacity.semanticWash), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

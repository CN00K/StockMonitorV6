import Foundation
import SwiftUI
import StockMonitorCore

@MainActor
enum QuotePresentation {
    static let maximumFreshnessAge: TimeInterval = 120
    private static let chineseLocale = Locale(identifier: "zh_CN")

    static func changeFraction(for quote: Quote) -> Double? {
        guard quote.previousClose.isFinite, quote.previousClose > 0,
              quote.price.isFinite else { return nil }
        return (quote.price - quote.previousClose) / quote.previousClose
    }

    static func freshnessState(for quote: Quote, now: Date = Date()) -> DataPresentationState? {
        guard quote.timestampIsProvider else { return .partial }
        return abs(now.timeIntervalSince(quote.timestamp)) <= maximumFreshnessAge ? nil : .stale
    }

    static func number(_ value: Double?, maximumFractionDigits: Int = 2) -> String {
        guard let value, value.isFinite else { return "未知" }
        let formatter = NumberFormatter()
        formatter.locale = chineseLocale
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = maximumFractionDigits
        return formatter.string(from: NSNumber(value: value)) ?? "未知"
    }

    static func percentagePoints(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "未知" }
        return "\(number(value))%"
    }

    static func signedPercentagePoints(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "未知" }
        let sign = value > 0 ? "+" : value < 0 ? "−" : ""
        return sign + percentagePoints(abs(value))
    }

    static func volumeRatio(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "未知" }
        return "\(number(value))×"
    }

    static func hasFreshMoneyFlow(_ quote: Quote, now: Date = Date()) -> Bool {
        guard let value = quote.mainNetInflow, value.isFinite,
              let timestamp = quote.moneyFlowTimestamp,
              let sourceID = quote.moneyFlowSourceID, !sourceID.isEmpty else { return false }
        return abs(now.timeIntervalSince(timestamp)) <= maximumFreshnessAge
    }
}

@MainActor
struct MarketDataLimitationsNote: View {
    @Environment(\.stockMonitorPalette) private var palette

    var body: some View {
        StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                Label("数据范围：公开来源轮询快照", systemImage: "info.circle.fill")
                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                Text("页面行情不是 Level-2，也不是逐笔实时行情。")
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                    .foregroundStyle(palette.inkSecondary)
                Text("不提供：Level-2 买卖盘档位与委托队列、逐笔成交、完整盘后回放。")
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                    .foregroundStyle(palette.inkSecondary)
                Text("分钟线仅为采样数据；来源可能延迟、缺失、限流或变更，来源时间未知时不视为实时。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

import SwiftUI
import StockMonitorCore

@MainActor
struct StockDetailView: View {
    let code: String
    let quote: Quote?
    @ObservedObject var model: MonitorViewModel
    @Environment(\.stockMonitorPalette) private var palette
    @State private var selectedSection: StockDetailSection = .overview
    @State private var dailyBars: [DailyBar] = []
    @State private var isLoadingHistory = false
    @State private var historyError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                identityHeader
                Picker("详情分区", selection: $selectedSection) {
                    ForEach(StockDetailSection.allCases) { section in
                        Text(section.title).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityLabel("证券详情分区")

                switch selectedSection {
                case .overview:
                    overviewContent
                case .history:
                    historyContent
                }
            }
            .padding(StockMonitorTokens.Space.large)
        }
        .background(palette.paper0)
        .navigationTitle("证券详情")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: code) { await loadHistory() }
    }

    private var identityHeader: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                    Text(quote.map { $0.name.isEmpty ? code : $0.name } ?? code)
                        .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                        .lineLimit(2)
                    Text(code)
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote, design: .monospaced))
                        .foregroundStyle(palette.inkMuted)
                }
                if let quote {
                    HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.medium) {
                        Text(ChartFormatters.price(quote.price))
                            .font(.system(size: StockMonitorTokens.TypeScale.display, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.inkPrimary)
                            .monospacedDigit()
                        if let change = QuotePresentation.changeFraction(for: quote) {
                            StockMonitorChangeBadge(
                                direction: change > 0 ? .up : change < 0 ? .down : .flat,
                                valueText: ChartFormatters.signedPercent(change))
                        } else {
                            Text("涨跌未知")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                        }
                    }
                    StockMonitorProvenanceLine(source: quote.sourceID, timestamp: quote.timestamp,
                        cadence: "已加载报价", isProviderTimestamp: quote.timestampIsProvider)
                    if let freshness = QuotePresentation.freshnessState(for: quote) {
                        StockMonitorDataStatePanel(state: freshness,
                            detail: freshness == .stale
                                ? "来源时间已超过 120 秒新鲜度窗口；该报价不标为实时。"
                                : "来源没有提供可确认的行情时间；本页不推断实时性。")
                    }
                } else {
                    StockMonitorDataStatePanel(state: .partial,
                        detail: "当前没有可显示报价；价格与涨跌字段保持未知。详情仍可查看本机已缓存日线。")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var overviewContent: some View {
        if let quote {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: StockMonitorTokens.Space.small),
                                GridItem(.flexible(), spacing: StockMonitorTokens.Space.small)],
                      spacing: StockMonitorTokens.Space.small) {
                StockMonitorMetricCard(label: "昨收", value: ChartFormatters.price(quote.previousClose))
                StockMonitorMetricCard(label: "开盘", value: ChartFormatters.price(quote.open))
                StockMonitorMetricCard(label: "最高", value: ChartFormatters.price(quote.high))
                StockMonitorMetricCard(label: "最低", value: ChartFormatters.price(quote.low))
                StockMonitorMetricCard(label: "成交量", value: ChartFormatters.shareVolume(Double(quote.volume)))
                StockMonitorMetricCard(label: "量比", value: QuotePresentation.volumeRatio(quote.volumeRatio))
                StockMonitorMetricCard(label: "换手率", value: QuotePresentation.percentagePoints(quote.turnoverRate),
                    detail: "来源字段；缺失时显示未知")
                StockMonitorMetricCard(label: "PE（动态）", value: QuotePresentation.number(quote.dynamicPE),
                    detail: "不是 PE-TTM")
            }
            StockMonitorDataStatePanel(state: .partial,
                detail: "概览只呈现当前已加载的来源报价字段；来源未提供的指标保持未知，不作推算。")
        } else {
            StockMonitorDataStatePanel(state: .empty,
                detail: "尚无当前报价快照。切换到历史页可查看本机缓存日线；不会因打开详情而联网。")
        }
    }

    private var historyContent: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                HStack {
                    Label("本机缓存日线", systemImage: "internaldrive")
                        .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    Spacer(minLength: StockMonitorTokens.Space.small)
                    Button {
                        Task { await loadHistory() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .disabled(isLoadingHistory)
                    .accessibilityLabel("重新读取本机日线缓存")
                }
                Text("仅查询 SQLite 已保存记录；打开或刷新此页都不会请求网络。日线未复权。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if isLoadingHistory {
                    StockMonitorDataStatePanel(state: .loading, detail: "正在读取本机已缓存日线。")
                } else if let historyError {
                    StockMonitorDataStatePanel(state: .error,
                        detail: "本机日线读取失败：\(historyError)",
                        actionTitle: "重试读取",
                        action: { Task { await loadHistory() } })
                } else if dailyBars.isEmpty {
                    StockMonitorDataStatePanel(state: .empty,
                        detail: "本机没有这只股票的日线缓存。此页面不自动补齐历史行情。")
                } else {
                    historySummary
                    HStack {
                        Text("日K线")
                            .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                        Spacer()
                        Text("\(dailyBars.count) 条本机缓存")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                    }
                    HStack(spacing: StockMonitorTokens.Space.medium) {
                        candleLegend("收涨", color: palette.dataUp)
                        candleLegend("收跌", color: palette.dataDown)
                        candleLegend("平盘", color: palette.dataFlat)
                        Spacer(minLength: 0)
                    }
                    StockDailyCandleChart(bars: dailyBars)
                    Text("每根蜡烛对应一条未复权日线；最高 / 最低为影线，开盘 / 收盘为实体。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    Divider().overlay(palette.hair)
                    VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                        Text("最近记录")
                            .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                            .foregroundStyle(palette.inkPrimary)
                        ForEach(Array(dailyBars.suffix(8).reversed()), id: \.tradeDate) { bar in
                            DailyHistoryRow(bar: bar)
                        }
                    }
                    if let latest = dailyBars.last {
                        Text("来源：\(latest.sourceID) · 本机抓取时间：\(latest.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                            .accessibilityElement(children: .combine)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var historySummary: some View {
        let first = dailyBars.first
        let last = dailyBars.last
        let change = sampleChange
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: StockMonitorTokens.Space.small),
                                   GridItem(.flexible(), spacing: StockMonitorTokens.Space.small)],
                         spacing: StockMonitorTokens.Space.small) {
            StockMonitorMetricCard(label: "缓存记录", value: "\(dailyBars.count) 条",
                detail: "最多展示最近 60 条")
            StockMonitorMetricCard(label: "交易日范围",
                value: first.map { $0.tradeDate.formatted(date: .abbreviated, time: .omitted) } ?? "未知",
                detail: last.map { "至 \($0.tradeDate.formatted(date: .abbreviated, time: .omitted))" } ?? "")
            StockMonitorMetricCard(label: "首末收盘变化",
                value: change.map(ChartFormatters.signedPercent) ?? "样本不足",
                detail: "首条与末条缓存收盘价比较",
                semanticColor: change.map { $0 > 0 ? palette.dataUp : $0 < 0 ? palette.dataDown : palette.dataFlat })
            StockMonitorMetricCard(label: "最新缓存收盘", value: ChartFormatters.price(last?.close),
                detail: last.map { $0.tradeDate.formatted(date: .abbreviated, time: .omitted) } ?? "")
        }
    }

    private var sampleChange: Double? {
        guard let first = dailyBars.first, let last = dailyBars.last,
              dailyBars.count > 1, first.close.isFinite, first.close > 0,
              last.close.isFinite else { return nil }
        return (last.close - first.close) / first.close
    }

    private func candleLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: StockMonitorTokens.Space.xsmall) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func loadHistory() async {
        guard !isLoadingHistory else { return }
        isLoadingHistory = true
        historyError = nil
        defer { isLoadingHistory = false }
        do {
            let cached = try await model.cachedDailyBars(for: code, limit: 60)
            dailyBars = cached.filter { bar in
                let prices = [bar.open, bar.high, bar.low, bar.close]
                return prices.allSatisfy(\.isFinite)
                    && bar.open > 0 && bar.low > 0
                    && bar.low <= min(bar.open, bar.close)
                    && bar.high >= max(bar.open, bar.close)
            }
            .sorted { $0.tradeDate < $1.tradeDate }
        } catch {
            guard !Task.isCancelled else { return }
            historyError = error.localizedDescription
            dailyBars = []
        }
    }
}

private enum StockDetailSection: String, CaseIterable, Identifiable {
    case overview
    case history
    var id: String { rawValue }
    var title: String { self == .overview ? "概览" : "K线" }
}

@MainActor
private struct DailyHistoryRow: View {
    @Environment(\.stockMonitorPalette) private var palette
    let bar: DailyBar

    var body: some View {
        HStack(spacing: StockMonitorTokens.Space.small) {
            Text(bar.tradeDate.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("开 \(ChartFormatters.price(bar.open))")
            Text("高 \(ChartFormatters.price(bar.high))")
            Text("低 \(ChartFormatters.price(bar.low))")
            Text("收 \(ChartFormatters.price(bar.close))")
                .foregroundStyle(palette.inkPrimary)
        }
        .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
        .lineLimit(1)
        .minimumScaleFactor(StockMonitorTokens.Scale.metricMinimum)
        .padding(.vertical, StockMonitorTokens.Space.xsmall)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(bar.tradeDate.formatted(date: .complete, time: .omitted))，开盘 \(ChartFormatters.price(bar.open))，最高 \(ChartFormatters.price(bar.high))，最低 \(ChartFormatters.price(bar.low))，收盘 \(ChartFormatters.price(bar.close))")
    }
}

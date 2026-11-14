import SwiftUI

enum ComponentSkeletonKind: String, CaseIterable, Identifiable {
    case appSurface, sectionHeader, metricCard, metricValue, deltaBadge, dataProvenance
    case cadenceBadge, freshnessBadge, sourceChip, stockIdentity, quoteStatGrid, trendSparkline
    case priceChart, volumeChart, marketIndexCard, breadthCard, marketTurnoverCard, watchlistRow
    case alertSignalRow, eventCard, positionRow, ruleControl, filterChip, searchField
    case heatmapCell, treemapTile, flowBar, gaugeFrame, chartLegend, chartAxis
    case notificationBanner, tabItem

    var id: String { rawValue }

    var title: String {
        switch self {
        case .appSurface: "页面表面"
        case .sectionHeader: "分区标题"
        case .metricCard: "指标卡"
        case .metricValue: "指标数值"
        case .deltaBadge: "涨跌幅徽标"
        case .dataProvenance: "数据来源"
        case .cadenceBadge: "采样频率"
        case .freshnessBadge: "数据新鲜度"
        case .sourceChip: "数据源标签"
        case .stockIdentity: "证券信息"
        case .quoteStatGrid: "行情指标网格"
        case .trendSparkline: "趋势迷你图"
        case .priceChart: "价格图表"
        case .volumeChart: "成交量图"
        case .marketIndexCard: "指数卡"
        case .breadthCard: "市场宽度"
        case .marketTurnoverCard: "两市成交额"
        case .watchlistRow: "自选行"
        case .alertSignalRow: "告警信号行"
        case .eventCard: "资讯事件卡"
        case .positionRow: "持仓行"
        case .ruleControl: "规则控制"
        case .filterChip: "筛选标签"
        case .searchField: "搜索框"
        case .heatmapCell: "热力图单元"
        case .treemapTile: "矩形树区块"
        case .flowBar: "资金流条"
        case .gaugeFrame: "仪表框"
        case .chartLegend: "图例"
        case .chartAxis: "坐标轴"
        case .notificationBanner: "通知横幅"
        case .tabItem: "导航标签"
        }
    }

    fileprivate var layout: SkeletonLayout {
        switch self {
        case .sectionHeader, .stockIdentity, .watchlistRow, .alertSignalRow, .eventCard,
             .positionRow, .notificationBanner, .tabItem:
            .row
        case .priceChart, .volumeChart, .trendSparkline, .gaugeFrame:
            .chart
        case .quoteStatGrid, .breadthCard, .marketTurnoverCard, .heatmapCell, .treemapTile:
            .grid
        case .deltaBadge, .cadenceBadge, .freshnessBadge, .sourceChip, .filterChip, .chartLegend:
            .badge
        case .ruleControl, .searchField, .chartAxis:
            .form
        case .appSurface, .metricCard, .metricValue, .dataProvenance, .marketIndexCard, .flowBar:
            .metric
        }
    }
}

private enum SkeletonLayout {
    case row, chart, grid, badge, form, metric
}

struct StockMonitorSurface<Content: View>: View {
    @Environment(\.stockMonitorPalette) private var palette
    private let content: Content
    private let padding: CGFloat

    init(padding: CGFloat = StockMonitorTokens.Space.large,
         @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(palette.paper1, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.panel))
            .overlay {
                RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.panel)
                    .stroke(palette.hair, lineWidth: StockMonitorTokens.Size.hairline)
            }
    }
}

struct StockMonitorMetricCard: View {
    @Environment(\.stockMonitorPalette) private var palette
    let label: String
    let value: String
    var detail: String? = nil
    var semanticColor: Color? = nil

    var body: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                Text(label)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                    .foregroundStyle(palette.inkMuted)
                Text(value)
                    .font(.system(size: StockMonitorTokens.TypeScale.titleLarge, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(semanticColor ?? palette.inkPrimary)
                    .minimumScaleFactor(StockMonitorTokens.Scale.metricMinimum)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                        .foregroundStyle(palette.inkSecondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget, alignment: .leading)
        }
    }
}

struct StockMonitorProvenanceLine: View {
    @Environment(\.stockMonitorPalette) private var palette
    let source: String
    let timestamp: Date?
    let cadence: String
    let isProviderTimestamp: Bool

    var body: some View {
        HStack(spacing: StockMonitorTokens.Space.small) {
            Image(systemName: isProviderTimestamp ? "checkmark.seal" : "clock")
                .accessibilityHidden(true)
            Text(source)
            Text("·")
            Text(cadence)
            Text("·")
            if let timestamp, isProviderTimestamp {
                Text(ChartFormatters.time(timestamp))
                    .monospacedDigit()
            } else {
                Text("来源时间未知")
            }
        }
        .font(.system(size: StockMonitorTokens.TypeScale.caption))
        .foregroundStyle(palette.inkMuted)
        .accessibilityElement(children: .combine)
    }
}

struct StockMonitorDataStatePanel: View {
    @Environment(\.stockMonitorPalette) private var palette
    let state: DataPresentationState
    let detail: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        StockMonitorSurface {
            HStack(alignment: .top, spacing: StockMonitorTokens.Space.large) {
                if state == .loading {
                    ProgressView().tint(palette.accent)
                        .frame(width: StockMonitorTokens.Size.minimumHitTarget,
                               height: StockMonitorTokens.Size.minimumHitTarget)
                } else {
                    Image(systemName: state.symbolName)
                        .font(.system(size: StockMonitorTokens.TypeScale.title))
                        .foregroundStyle(state == .error ? palette.dataDown : palette.accent2)
                        .frame(width: StockMonitorTokens.Size.minimumHitTarget,
                               height: StockMonitorTokens.Size.minimumHitTarget)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                    Text(state.title)
                        .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    Text(detail)
                        .font(.system(size: StockMonitorTokens.TypeScale.body))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let actionTitle, let action {
                        Button(actionTitle, action: action)
                            .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                            .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                            .foregroundStyle(palette.accent)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }
}

enum DataPresentationState: String, CaseIterable, Identifiable, Equatable {
    case loading, empty, partial, error, stale

    var id: String { rawValue }

    var title: String {
        switch self {
        case .loading: "加载中"
        case .empty: "暂无数据"
        case .partial: "数据不完整"
        case .error: "加载失败"
        case .stale: "数据已过期"
        }
    }

    var symbolName: String {
        switch self {
        case .loading: "arrow.triangle.2.circlepath"
        case .empty: "tray"
        case .partial: "exclamationmark.circle"
        case .error: "wifi.exclamationmark"
        case .stale: "clock.badge.exclamationmark"
        }
    }
}

struct StockMonitorComponentSkeleton: View {
    @Environment(\.stockMonitorPalette) private var palette
    let kind: ComponentSkeletonKind

    var body: some View {
        StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Text(kind.title)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                    .foregroundStyle(palette.inkMuted)
                specimen
            }
            .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget, alignment: .leading)
        }
        .accessibilityLabel(Text("\(kind.title)，组件占位"))
    }

    @ViewBuilder
    private var specimen: some View {
        switch kind.layout {
        case .row:
            HStack(spacing: StockMonitorTokens.Space.medium) {
                RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small)
                    .fill(palette.paper3)
                    .frame(width: StockMonitorTokens.Size.minimumHitTarget,
                           height: StockMonitorTokens.Size.minimumHitTarget)
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                    skeletonLine(width: .twoThirds)
                    skeletonLine(width: .half)
                }
                Spacer(minLength: StockMonitorTokens.Space.small)
                skeletonLine(width: .quarter)
            }
        case .chart:
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.medium)
                    .fill(palette.paper2)
                    .frame(height: StockMonitorTokens.Size.chartSkeletonHeight)
                HStack { skeletonLine(width: .quarter); Spacer(); skeletonLine(width: .quarter) }
            }
        case .grid:
            HStack(spacing: StockMonitorTokens.Space.small) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small)
                        .fill(palette.heatScale[index])
                        .frame(maxWidth: .infinity)
                        .frame(height: StockMonitorTokens.Size.chartSkeletonHeight / 2)
                }
            }
        case .badge:
            HStack(spacing: StockMonitorTokens.Space.small) {
                Capsule().fill(palette.paper3).frame(width: StockMonitorTokens.Size.minimumHitTarget,
                                                    height: StockMonitorTokens.Space.large)
                skeletonLine(width: .half)
            }
        case .form:
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                skeletonLine(width: .twoThirds)
                RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small)
                    .fill(palette.paper2)
                    .frame(height: StockMonitorTokens.Size.minimumHitTarget)
            }
        case .metric:
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                skeletonLine(width: .quarter)
                skeletonLine(width: .twoThirds, height: StockMonitorTokens.TypeScale.title)
                skeletonLine(width: .half)
            }
        }
    }

    private func skeletonLine(width: SkeletonWidth, height: CGFloat = StockMonitorTokens.TypeScale.footnote) -> some View {
        RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.pill)
            .fill(palette.paper3)
            .frame(maxWidth: width.maximum, alignment: .leading)
            .frame(height: height)
    }
}

private enum SkeletonWidth {
    case quarter, half, twoThirds

    var maximum: CGFloat {
        switch self {
        case .quarter: StockMonitorTokens.Size.skeletonQuarter
        case .half: StockMonitorTokens.Size.skeletonHalf
        case .twoThirds: StockMonitorTokens.Size.skeletonTwoThirds
        }
    }
}

struct StockMonitorComponentCatalog: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())],
                  spacing: StockMonitorTokens.Space.medium) {
            ForEach(ComponentSkeletonKind.allCases) { kind in
                StockMonitorComponentSkeleton(kind: kind)
            }
        }
    }
}

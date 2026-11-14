import SwiftUI
import StockMonitorCore

@MainActor
struct WatchlistView: View {
    @ObservedObject var model: MonitorViewModel
    @Environment(\.stockMonitorPalette) private var palette
    @State private var detailPath: [String] = []

    private var quotesByCode: [String: Quote] {
        Dictionary((model.state.latestSnapshot?.quotes ?? []).map { ($0.code, $0) },
                   uniquingKeysWith: { _, newest in newest })
    }

    var body: some View {
        NavigationStack(path: $detailPath) {
            ScrollView {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.large) {
                    addCodePanel
                    MarketDataLimitationsNote()
                    if model.state.watchCodes.isEmpty {
                        StockMonitorDataStatePanel(state: .empty,
                            detail: "自选列表为空。添加 6 位证券代码后，行情将在现有前台会话中按节奏请求。")
                    } else {
                        ForEach(model.state.watchCodes, id: \.self) { code in
                            if let quote = quotesByCode[code] {
                                WatchQuoteCard(
                                    quote: quote,
                                    limitPair: model.state.latestSnapshot?.limits[code],
                                    limitPriceStatus: model.state.latestSnapshot?.limitPriceStatus ?? model.state.limitPriceStatus,
                                    isSelectedForAnalysis: model.selectedAnalystCode == code,
                                    onSelect: { model.selectedAnalystCode = code },
                                    onOpenDetail: { detailPath.append(code) },
                                    onRemove: { model.removeCode(code) })
                            } else {
                                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                                    StockMonitorDataStatePanel(state: model.state.latestSnapshot == nil ? .loading : .partial,
                                        detail: "\(code) 尚无可显示报价；缺失字段保持未知。")
                                    Button {
                                        detailPath.append(code)
                                    } label: {
                                        Label("查看 \(code) 详情", systemImage: "arrow.right")
                                            .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget,
                                                   alignment: .leading)
                                    }
                                    .buttonStyle(.bordered)
                                    .accessibilityHint("查看本机已有数据；不会自动请求行情或历史。")
                                }
                            }
                        }
                    }
                    Text("行情数据可能延迟或过期。页面显示来源时间；过期快照不会被标成实时。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(StockMonitorTokens.Space.large)
            }
            .background(palette.paper0)
            .refreshable { await model.refreshNow() }
            .navigationTitle("自选")
            .navigationDestination(for: String.self) { code in
                StockDetailView(code: code, quote: quotesByCode[code], model: model)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await model.refreshNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .accessibilityLabel("手动刷新自选行情")
                }
            }
        }
        .tint(palette.accent)
    }

    private var addCodePanel: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                Text("添加沪深证券")
                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                    .foregroundStyle(palette.inkPrimary)
                HStack(spacing: StockMonitorTokens.Space.medium) {
                    TextField("6 位证券代码", text: $model.codeInput)
                        .keyboardType(.numberPad)
                        .textContentType(.none)
                        .font(.system(size: StockMonitorTokens.TypeScale.body, design: .monospaced))
                        .padding(.horizontal, StockMonitorTokens.Space.medium)
                        .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                        .background(palette.paper2, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small))
                        .accessibilityLabel("输入沪深证券代码")
                    Button {
                        model.addCode()
                    } label: {
                        Label("添加", systemImage: "plus")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isValidCode)
                    .accessibilityHint("添加到自选；报价由已配置的前台行情源按会话节奏获取")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isValidCode: Bool {
        model.codeInput.count == 6 && model.codeInput.allSatisfy(\.isNumber)
    }
}

@MainActor
private struct WatchQuoteCard: View {
    @Environment(\.stockMonitorPalette) private var palette
    let quote: Quote
    let limitPair: LimitPair?
    let limitPriceStatus: String
    let isSelectedForAnalysis: Bool
    let onSelect: () -> Void
    let onOpenDetail: () -> Void
    let onRemove: () -> Void

    private var change: Double? { QuotePresentation.changeFraction(for: quote) }
    private var flowFresh: Bool { QuotePresentation.hasFreshMoneyFlow(quote) }

    var body: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                HStack(spacing: StockMonitorTokens.Space.medium) {
                    Button(action: onSelect) {
                        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                            HStack(spacing: StockMonitorTokens.Space.small) {
                                Text(quote.name)
                                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                                    .foregroundStyle(palette.inkPrimary)
                                    .lineLimit(1)
                                if isSelectedForAnalysis {
                                    Label("分析候选", systemImage: "checkmark.circle.fill")
                                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                        .foregroundStyle(palette.accent)
                                }
                            }
                            Text(quote.code)
                                .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                                .foregroundStyle(palette.inkMuted)
                        }
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget,
                               alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择\(quote.name) \(quote.code)作为分析候选")

                    VStack(alignment: .trailing, spacing: StockMonitorTokens.Space.xsmall) {
                        Text(ChartFormatters.price(quote.price))
                            .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold, design: .rounded))
                            .foregroundStyle(palette.inkPrimary)
                            .monospacedDigit()
                        if let change {
                            StockMonitorChangeBadge(
                                direction: change > 0 ? .up : change < 0 ? .down : .flat,
                                valueText: ChartFormatters.signedPercent(change))
                        } else {
                            Text("涨跌未知")
                                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                .foregroundStyle(palette.inkMuted)
                        }
                    }

                    Button(role: .destructive, action: onRemove) {
                        Image(systemName: "minus.circle")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .accessibilityLabel("从自选中移除\(quote.name) \(quote.code)")
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: StockMonitorTokens.Space.small),
                                    GridItem(.flexible(), spacing: StockMonitorTokens.Space.small)],
                          spacing: StockMonitorTokens.Space.small) {
                    WatchMetricCell(label: "成交额", value: ChartFormatters.unsignedCNYAmount(quote.amount))
                    WatchMetricCell(label: "量比", value: QuotePresentation.volumeRatio(quote.volumeRatio))
                    WatchMetricCell(label: "换手率", value: QuotePresentation.percentagePoints(quote.turnoverRate))
                    WatchMetricCell(label: "PE（动态）", value: QuotePresentation.number(quote.dynamicPE))
                    WatchMetricCell(label: "总市值", value: ChartFormatters.unsignedCNYAmount(quote.totalMarketValue))
                    WatchMetricCell(label: "主力净流入源值",
                        value: flowFresh ? QuotePresentation.number(quote.mainNetInflow) : flowUnavailableLabel,
                        detail: flowFresh ? "单位未独立验证" : "来源/时间未达新鲜度要求")
                }

                StockMonitorProvenanceLine(source: quote.sourceID, timestamp: quote.timestamp,
                    cadence: "前台行情轮询", isProviderTimestamp: quote.timestampIsProvider)
                if let freshness = QuotePresentation.freshnessState(for: quote) {
                    Label(freshness == .stale ? "来源行情已过 120 秒新鲜度窗口" : "来源时间未知",
                          systemImage: freshness.symbolName)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(freshness == .stale ? palette.dataDown : palette.accent2)
                    .accessibilityElement(children: .combine)
                }

                Button(action: onOpenDetail) {
                    Label("查看本机详情", systemImage: "arrow.right")
                        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget,
                               alignment: .leading)
                }
                .buttonStyle(.bordered)
                .accessibilityHint("查看当前报价字段与已缓存的未复权日线；不会触发网络请求。")

                Divider().overlay(palette.hair)
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                    if let limitPair {
                        Text("本地公式估算限价（非权威）：涨停 \(ChartFormatters.price(limitPair.up)) · 跌停 \(ChartFormatters.price(limitPair.down))")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkSecondary)
                    } else {
                        Text("涨跌停价未知：当前证券没有可用估算值。")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.accent2)
                    }
                    Text(limitPriceStatus)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private var flowUnavailableLabel: String {
        guard quote.mainNetInflow != nil else { return "未知" }
        guard quote.moneyFlowTimestamp != nil, quote.moneyFlowSourceID != nil else { return "来源时间未知" }
        return "已过期"
    }
}

private struct WatchMetricCell: View {
    @Environment(\.stockMonitorPalette) private var palette
    let label: String
    let value: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(label)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
            Text(value)
                .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(StockMonitorTokens.Scale.metricMinimum)
            if let detail {
                Text(detail)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: StockMonitorTokens.Size.minimumHitTarget, alignment: .leading)
        .padding(StockMonitorTokens.Space.small)
        .background(palette.paper2, in: RoundedRectangle(cornerRadius: StockMonitorTokens.Radius.small))
        .accessibilityElement(children: .combine)
    }
}

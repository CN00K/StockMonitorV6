import SwiftUI
import StockMonitorCore

@MainActor
struct MarketOverviewView: View {
    @ObservedObject var model: MonitorViewModel
    let openTab: (StockMonitorTab) -> Void
    @Environment(\.stockMonitorPalette) private var palette
    @State private var isWorkbenchPresented = false
    @State private var isBoardPresented = false

    private var snapshot: MarketSnapshot? { model.state.latestSnapshot }
    private var coverage: MarketCoverageSnapshot? { snapshot?.marketCoverage }
    private var scanStatus: SourceStatus? {
        coverage?.status ?? model.state.sourceStatuses.first(where: { $0.sourceID == "eastmoney.clist" })
    }
    private var liveCoverageDetail: String {
        guard let coverage else { return "尚无扫描结果；覆盖分母未知。" }
        guard let total = coverage.summary.reportedTotalCount,
              let fraction = coverage.summary.sampleCoverageFraction else {
            return "已返回 \(coverage.status.returnedCount) 行；服务端 total 或覆盖率未知。"
        }
        return "返回 \(coverage.status.returnedCount)/服务端报告 \(total) 行（\(QuotePresentation.percentagePoints(fraction * 100))；非交易所独立清单）"
    }

    private func scanCompletenessDetail(_ summary: MarketScanSummary) -> String {
        if summary.coverageComplete {
            return "唯一返回数与 clist 报告 total 对齐；这不代表交易所独立核验的完整上市证券清单。涨停、跌停与炸板家数仍未知。"
        }
        var reasons: [String] = []
        if summary.truncated { reasons.append("触及页数/证券数上限") }
        if summary.invalidRowCount > 0 { reasons.append("无效行 \(summary.invalidRowCount) 条") }
        if summary.duplicateRowCount > 0 { reasons.append("重复行 \(summary.duplicateRowCount) 条") }
        if summary.reportedTotalCount == nil { reasons.append("服务端 total 未知") }
        if reasons.isEmpty { reasons.append("唯一返回数未与服务端 total 对齐，或数据源报告变化") }
        return "覆盖不完整（\(reasons.joined(separator: "、"))）；不得把样本计数解释为全市场总数。涨停、跌停与炸板家数仍未知。"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xlarge) {
                    sessionSection
                    MarketDataLimitationsNote()
                    indexSection
                    marketSampleSection
                    fullUniverseScanSection
                    limitPriceSection
                    topMoversSection
                }
                .padding(StockMonitorTokens.Space.large)
            }
            .background(palette.paper0)
            .refreshable { await model.refreshNow() }
            .navigationTitle("市场")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isWorkbenchPresented = true
                    } label: {
                        Image(systemName: "square.grid.2x2")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .accessibilityLabel("打开工作台看板")
                    .accessibilityHint("查看当前本机会话、自选、持仓和未读信号")

                    Button {
                        isBoardPresented = true
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .accessibilityLabel("打开全屏行情看板")
                    .accessibilityHint("隐藏标签导航，在全屏页面查看当前本机指数、自选和扫描样本")

                    Button {
                        Task { await model.refreshNow() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                   minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .accessibilityLabel("手动刷新行情")
                }
            }
        }
        .sheet(isPresented: $isWorkbenchPresented) {
            WorkbenchView(model: model) { tab in
                openTab(tab)
                isWorkbenchPresented = false
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $isBoardPresented) {
            BoardModeView(model: model)
        }
        .tint(palette.accent)
    }

    private var sessionSection: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                HStack(alignment: .firstTextBaseline) {
                    Text("前台行情会话")
                        .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    Spacer(minLength: StockMonitorTokens.Space.small)
                    Text(phaseLabel)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                        .foregroundStyle(phaseColor)
                }
                Label("监测只在 App 前台开启时运行", systemImage: "iphone")
                    .font(.system(size: StockMonitorTokens.TypeScale.body))
                    .foregroundStyle(palette.inkSecondary)
                Text(calendarLabel)
                    .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                    .foregroundStyle(palette.inkSecondary)
                    if let capturedAt = snapshot?.capturedAt {
                        Text("本机最近快照：\(ChartFormatters.dateTime(capturedAt))")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                    }
                if let error = model.state.lastError, !error.isEmpty {
                    Text(error)
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                        .foregroundStyle(palette.dataDown)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    private var indexSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionTitle("核心指数", detail: "报价来自当前快照；旧值会标记过期")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: StockMonitorTokens.Space.medium),
                                GridItem(.flexible(), spacing: StockMonitorTokens.Space.medium)],
                      spacing: StockMonitorTokens.Space.medium) {
                ForEach(MarketIndex.core) { index in
                    if let quote = snapshot?.indexQuotes.first(where: { $0.code == index.code }) {
                        IndexQuoteCard(index: index, quote: quote)
                    } else {
                        StockMonitorDataStatePanel(
                            state: snapshot == nil && isStarting ? .loading : .partial,
                            detail: "\(index.name)（\(index.code)）当前没有可用报价；不会用零值代替。")
                    }
                }
            }
        }
    }

    private var marketSampleSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionTitle("市场宽度 · 扫描样本", detail: liveCoverageDetail)
            if let coverage {
                let summary = coverage.summary
                let breadthTotal = summary.up + summary.flat + summary.down
                if coverage.status.returnedCount == 0 {
                    StockMonitorDataStatePanel(state: .empty,
                        detail: "扫描没有返回可统计的证券行；涨跌家数、成交额和主力净流入保持未知。")
                } else if breadthTotal > 0 {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: StockMonitorTokens.Space.small),
                                        GridItem(.flexible(), spacing: StockMonitorTokens.Space.small),
                                        GridItem(.flexible(), spacing: StockMonitorTokens.Space.small)],
                              spacing: StockMonitorTokens.Space.small) {
                        StockMonitorMetricCard(label: "上涨样本", value: "\(summary.up)",
                            detail: "扫描返回 \(coverage.status.returnedCount) 行", semanticColor: palette.dataUp)
                        StockMonitorMetricCard(label: "平盘样本", value: "\(summary.flat)",
                            detail: "涨跌幅字段可用", semanticColor: palette.dataFlat)
                        StockMonitorMetricCard(label: "下跌样本", value: "\(summary.down)",
                            detail: "涨跌幅字段可用", semanticColor: palette.dataDown)
                    }
                    MarketSampleBreadthBar(up: summary.up, flat: summary.flat, down: summary.down)
                } else {
                    StockMonitorDataStatePanel(state: .partial,
                        detail: "接口返回了证券行，但没有可用涨跌幅用于计算样本宽度；计数保持未知。")
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: StockMonitorTokens.Space.medium),
                                    GridItem(.flexible(), spacing: StockMonitorTokens.Space.medium)],
                          spacing: StockMonitorTokens.Space.medium) {
                    StockMonitorMetricCard(label: "扫描样本成交额",
                        value: summary.amount.map { ChartFormatters.unsignedCNYAmount($0) } ?? "未知",
                        detail: "仅对本次返回且有成交额的证券求和")
                    StockMonitorMetricCard(label: "扫描样本主力净流入源值",
                        value: summary.mainNetFlow.map { QuotePresentation.number($0) } ?? "未知",
                        detail: summary.mainNetFlow == nil ? "无可用字段" : "Eastmoney f62 合计；单位未独立验证")
                }
                if let distribution = coverage.sampleDistribution {
                    MarketSampleDistributionPanel(distribution: distribution)
                }
                StockMonitorDataStatePanel(state: .partial, detail: scanCompletenessDetail(summary))
                StockMonitorProvenanceLine(source: coverage.status.sourceID,
                    timestamp: coverage.status.providerTimestamp,
                    cadence: "显式前台行情轮询/有缓存",
                    isProviderTimestamp: coverage.status.providerTimestamp != nil)
                if let note = coverage.status.note, !note.isEmpty {
                    Text(note)
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error = coverage.status.error {
                    StockMonitorDataStatePanel(state: .error, detail: error)
                }
            } else if let status = scanStatus {
                StockMonitorDataStatePanel(state: status.error == nil ? .partial : .error,
                    detail: status.error ?? status.note ?? "扫描未返回可显示数据；宽度和资金流未知。")
                StockMonitorProvenanceLine(source: status.sourceID,
                    timestamp: status.providerTimestamp, cadence: "前台会话扫描",
                    isProviderTimestamp: status.providerTimestamp != nil)
            } else {
                StockMonitorDataStatePanel(state: isStarting ? .loading : .empty,
                    detail: "市场扫描尚无可用结果；宽度、成交额和资金流不会用零值补齐。")
            }
        }
    }

    private var fullUniverseScanSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionTitle("扩展市场扫描", detail: "显式触发；最多 60 页 / 6,000 只；当前进程缓存 15 分钟；不保证官方全集")
            StockMonitorSurface {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                    Text("扫描仅在你点击时启动，不会阻塞常规行情 tick。分页大小固定为 100，页数根据 clist 的服务端 total 推导并受 60 页 / 6,000 只上限约束；total 是供应方自报值，不是交易所独立清单。")
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button(action: model.refreshFullMarketCoverage) {
                        HStack(spacing: StockMonitorTokens.Space.small) {
                            if model.isLoadingFullMarketCoverage { ProgressView().tint(palette.paper0) }
                            Label(model.isLoadingFullMarketCoverage ? "正在扫描…" : "开始 / 查看扩展扫描",
                                  systemImage: "square.stack.3d.up")
                        }
                        .frame(minHeight: StockMonitorTokens.Size.minimumHitTarget)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(palette.accent)
                    .disabled(model.isLoadingFullMarketCoverage)
                    .accessibilityHint("最多请求 60 页、6,000 只证券；未覆盖结果会标记为部分，当前进程缓存 15 分钟")
                    if let message = model.fullMarketCoverageMessage {
                        Text(message)
                            .font(.system(size: StockMonitorTokens.TypeScale.caption))
                            .foregroundStyle(palette.inkMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let full = model.fullMarketCoverage {
                        let summary = full.summary
                        let total = summary.reportedTotalCount.map { String($0) } ?? "未知"
                        let ratio = summary.sampleCoverageFraction.map { QuotePresentation.percentagePoints($0 * 100) } ?? "未知"
                        LazyVGrid(columns: [GridItem(.flexible(), spacing: StockMonitorTokens.Space.small),
                                            GridItem(.flexible(), spacing: StockMonitorTokens.Space.small)],
                                  spacing: StockMonitorTokens.Space.small) {
                            StockMonitorMetricCard(label: "已返回证券行", value: String(full.status.returnedCount),
                                detail: "去重后实际解析")
                            StockMonitorMetricCard(label: "服务端报告总数", value: total,
                                detail: "接口字段，不代表官方清单")
                            StockMonitorMetricCard(label: "样本覆盖率", value: ratio,
                                detail: "已返回 / 服务端 total")
                            StockMonitorMetricCard(label: "上涨 / 平盘 / 下跌", value: "\(summary.up) / \(summary.flat) / \(summary.down)",
                                detail: "只按可解析的涨跌幅计算")
                        }
                        if let distribution = full.sampleDistribution {
                            MarketSampleDistributionPanel(distribution: distribution)
                        }
                        StockMonitorDataStatePanel(state: full.status.error == nil ? .partial : .error,
                            detail: full.status.error ?? scanCompletenessDetail(summary))
                        StockMonitorProvenanceLine(source: full.status.sourceID,
                            timestamp: full.status.providerTimestamp ?? full.status.fetchedAt,
                            cadence: "显式扫描 / 当前进程 15 分钟缓存",
                            isProviderTimestamp: full.status.providerTimestamp != nil)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var limitPriceSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionTitle("涨跌停与炸板", detail: "没有来源确认的市场家数")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: StockMonitorTokens.Space.small),
                                GridItem(.flexible(), spacing: StockMonitorTokens.Space.small),
                                GridItem(.flexible(), spacing: StockMonitorTokens.Space.small)],
                      spacing: StockMonitorTokens.Space.small) {
                StockMonitorMetricCard(label: "涨停家数", value: coverage?.summary.limitUp.map { String($0) } ?? "未知",
                    detail: "字段未验证")
                StockMonitorMetricCard(label: "跌停家数", value: coverage?.summary.limitDown.map { String($0) } ?? "未知",
                    detail: "字段未验证")
                StockMonitorMetricCard(label: "炸板家数", value: coverage?.summary.brokenSeal.map { String($0) } ?? "未知",
                    detail: "字段未验证")
            }
            StockMonitorSurface {
                VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                    Text("自选股逐只限价状态")
                        .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    Text(snapshot?.limitPriceStatus ?? model.state.limitPriceStatus)
                        .font(.system(size: StockMonitorTokens.TypeScale.footnote))
                        .foregroundStyle(palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("本地限价如有结果也只是公式估算，不是权威行情源；IPO 上市首 5 日和无法分类证券仍可能未知。")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var topMoversSection: some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
            sectionTitle("涨幅领先样本", detail: "Eastmoney clist 返回排序；可加入自选")
            if let coverage, !coverage.topQuotes.isEmpty {
                ForEach(Array(coverage.topQuotes.prefix(8))) { quote in
                    StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
                        HStack(spacing: StockMonitorTokens.Space.medium) {
                            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
                                Text(quote.name)
                                    .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                                    .foregroundStyle(palette.inkPrimary)
                                    .lineLimit(1)
                                Text(quote.code)
                                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                    .foregroundStyle(palette.inkMuted)
                                    .monospacedDigit()
                            }
                            Spacer(minLength: StockMonitorTokens.Space.small)
                            VStack(alignment: .trailing, spacing: StockMonitorTokens.Space.xsmall) {
                                Text(ChartFormatters.price(quote.price))
                                    .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                                    .foregroundStyle(palette.inkPrimary)
                                    .monospacedDigit()
                                if let change = quote.changePercent {
                                    StockMonitorChangeBadge(
                                        direction: change > 0 ? .up : change < 0 ? .down : .flat,
                                        valueText: QuotePresentation.signedPercentagePoints(change))
                                } else {
                                    Text("涨跌未知")
                                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                                        .foregroundStyle(palette.inkMuted)
                                }
                            }
                            Button {
                                model.codeInput = quote.code
                                model.addCode()
                            } label: {
                                Image(systemName: model.state.watchCodes.contains(quote.code) ? "checkmark" : "plus")
                                    .frame(minWidth: StockMonitorTokens.Size.minimumHitTarget,
                                           minHeight: StockMonitorTokens.Size.minimumHitTarget)
                            }
                            .disabled(model.state.watchCodes.contains(quote.code))
                            .accessibilityLabel(model.state.watchCodes.contains(quote.code)
                                ? "\(quote.name)已在自选中" : "添加\(quote.name)到自选")
                        }
                    }
                    .accessibilityElement(children: .contain)
                }
                if let status = scanStatus {
                    StockMonitorProvenanceLine(source: status.sourceID,
                        timestamp: status.providerTimestamp, cadence: "扫描样本排序",
                        isProviderTimestamp: status.providerTimestamp != nil)
                }
            } else {
                StockMonitorDataStatePanel(state: coverage == nil && isStarting ? .loading : .empty,
                    detail: "当前没有可显示的涨幅领先样本；不会用示例证券填充。")
            }
        }
    }

    private var isStarting: Bool {
        switch model.state.phase {
        case .coldStart, .reconciling: true
        case .closed, .live, .paused, .failed: false
        }
    }

    private var phaseLabel: String {
        switch model.state.phase {
        case .closed: "未启动"
        case .coldStart: "恢复本地状态"
        case .reconciling: "补齐可用历史"
        case .live: model.state.isMarketSession ? "交易时段监测中" : "前台会话运行"
        case .paused: "已暂停"
        case .failed: "启动失败"
        }
    }

    private var phaseColor: Color {
        switch model.state.phase {
        case .live: palette.dataUp
        case .failed: palette.dataDown
        case .closed, .coldStart, .reconciling, .paused: palette.accent2
        }
    }

    private var calendarLabel: String {
        switch MarketClock.tradingDayStatus() {
        case .open: "交易日历：当前日期在已核实年份/日期覆盖内；仅在规定时段轮询。"
        case .closed(let reason): "交易日历：休市（\(reason)）；Live Loop 暂停。"
        case .unknown: "交易日历：当前日期未知；不会假定开市，Live Loop 暂停。"
        }
    }

    private func sectionTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: StockMonitorTokens.Space.xsmall) {
            Text(title)
                .font(.system(size: StockMonitorTokens.TypeScale.title, weight: .semibold))
                .foregroundStyle(palette.inkPrimary)
            Text(detail)
                .font(.system(size: StockMonitorTokens.TypeScale.caption))
                .foregroundStyle(palette.inkMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct IndexQuoteCard: View {
    @Environment(\.stockMonitorPalette) private var palette
    let index: MarketIndex
    let quote: Quote

    private var change: Double? { QuotePresentation.changeFraction(for: quote) }

    var body: some View {
        StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                HStack(alignment: .firstTextBaseline, spacing: StockMonitorTokens.Space.small) {
                    Text(index.name)
                        .font(.system(size: StockMonitorTokens.TypeScale.body, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                        .lineLimit(1)
                    Spacer(minLength: StockMonitorTokens.Space.xsmall)
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
                Text(ChartFormatters.price(quote.price))
                    .font(.system(size: StockMonitorTokens.TypeScale.titleLarge, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.inkPrimary)
                    .monospacedDigit()
                    .minimumScaleFactor(StockMonitorTokens.Scale.metricMinimum)
                    .lineLimit(1)
                Text(index.code)
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .monospacedDigit()
                StockMonitorProvenanceLine(source: quote.sourceID, timestamp: quote.timestamp,
                    cadence: "前台轮询", isProviderTimestamp: quote.timestampIsProvider)
                if let state = QuotePresentation.freshnessState(for: quote) {
                    QuoteFreshnessNotice(state: state)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct QuoteFreshnessNotice: View {
    @Environment(\.stockMonitorPalette) private var palette
    let state: DataPresentationState

    var body: some View {
        Label(state == .stale ? "行情已过 120 秒新鲜度窗口" : "来源时间未知",
              systemImage: state.symbolName)
            .font(.system(size: StockMonitorTokens.TypeScale.caption))
            .foregroundStyle(state == .stale ? palette.dataDown : palette.accent2)
            .accessibilityElement(children: .combine)
    }
}


@MainActor
private struct MarketSampleBreadthBar: View {
    @Environment(\.stockMonitorPalette) private var palette
    let up: Int
    let flat: Int
    let down: Int

    private var total: Int { up + flat + down }

    var body: some View {
        StockMonitorSurface(padding: StockMonitorTokens.Space.medium) {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.small) {
                Text("返回样本涨跌比例")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .semibold))
                    .foregroundStyle(palette.inkSecondary)
                GeometryReader { proxy in
                    HStack(spacing: 0) {
                        Rectangle().fill(palette.dataUp)
                            .frame(width: proxy.size.width * CGFloat(up) / CGFloat(total))
                        Rectangle().fill(palette.dataFlat)
                            .frame(width: proxy.size.width * CGFloat(flat) / CGFloat(total))
                        Rectangle().fill(palette.dataDown)
                            .frame(width: proxy.size.width * CGFloat(down) / CGFloat(total))
                    }
                    .frame(height: StockMonitorTokens.Size.marketBarHeight)
                    .clipShape(Capsule())
                    .accessibilityHidden(true)
                }
                .frame(height: StockMonitorTokens.Size.marketBarHeight)
                HStack(spacing: StockMonitorTokens.Space.medium) {
                    Text("涨 \(up)").foregroundStyle(palette.dataUp)
                    Text("平 \(flat)").foregroundStyle(palette.dataFlat)
                    Text("跌 \(down)").foregroundStyle(palette.dataDown)
                    Spacer(minLength: StockMonitorTokens.Space.xsmall)
                    Text("n=\(total)").foregroundStyle(palette.inkMuted)
                }
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
private struct MarketSampleDistributionPanel: View {
    @Environment(\.stockMonitorPalette) private var palette
    let distribution: MarketScanDistribution

    private var maximumBucketCount: Int {
        max(1, distribution.buckets.map(\.count).max() ?? 0)
    }

    var body: some View {
        StockMonitorSurface {
            VStack(alignment: .leading, spacing: StockMonitorTokens.Space.medium) {
                HStack {
                    Text("扫描样本涨跌幅分布")
                        .font(.system(size: StockMonitorTokens.TypeScale.subhead, weight: .semibold))
                        .foregroundStyle(palette.inkPrimary)
                    Spacer(minLength: StockMonitorTokens.Space.small)
                    Text("\(distribution.sampleCount) 只")
                        .font(.system(size: StockMonitorTokens.TypeScale.caption))
                        .foregroundStyle(palette.inkMuted)
                        .monospacedDigit()
                }
                HStack(spacing: StockMonitorTokens.Space.medium) {
                    Text("均值 \(QuotePresentation.signedPercentagePoints(distribution.meanPercentPoints))")
                    Text("中位数 \(QuotePresentation.signedPercentagePoints(distribution.medianPercentPoints))")
                }
                .font(.system(size: StockMonitorTokens.TypeScale.caption, weight: .medium))
                .foregroundStyle(palette.inkSecondary)
                ForEach(distribution.buckets) { bucket in
                    HStack(spacing: StockMonitorTokens.Space.small) {
                        Text(bucket.label)
                            .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                            .foregroundStyle(palette.inkMuted)
                            .lineLimit(1)
                            .minimumScaleFactor(StockMonitorTokens.Scale.metricMinimum)
                            .frame(width: StockMonitorTokens.Size.marketBucketLabelWidth, alignment: .leading)
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(palette.paper2)
                                Capsule().fill(color(for: bucket))
                                    .frame(width: proxy.size.width * CGFloat(bucket.count) / CGFloat(maximumBucketCount))
                            }
                        }
                        .frame(height: StockMonitorTokens.Size.marketBarHeight)
                        Text("\(bucket.count)")
                            .font(.system(size: StockMonitorTokens.TypeScale.caption, design: .monospaced))
                            .foregroundStyle(palette.inkSecondary)
                            .frame(width: StockMonitorTokens.Size.marketBucketCountWidth, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                }
                Text("只统计本次 clist 返回且有涨跌幅的证券；分页上限之外的证券不在样本内，不代表全市场分布或情绪指数。")
                    .font(.system(size: StockMonitorTokens.TypeScale.caption))
                    .foregroundStyle(palette.inkMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    private func color(for bucket: MarketChangeBucket) -> Color {
        if bucket.id < 4 { palette.dataDown }
        else if bucket.id == 4 { palette.dataFlat }
        else { palette.dataUp }
    }
}
